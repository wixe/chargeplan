import Foundation
import Darwin

public final class UnixSocketServer {
    public static let defaultSocketPath = "/var/run/chargeplan.sock"
    public static let legacySocketPath = "/var/run/chargecap.sock"
    
    private let socketPath: String
    private var serverFD: Int32 = -1
    private var isRunning = false
    private weak var governor: AIGovernor?
    private let acceptQueue = DispatchQueue(label: "io.github.wixe.chargeplan.ipc", qos: .utility)
    
    public init(socketPath: String = UnixSocketServer.defaultSocketPath, governor: AIGovernor) {
        self.socketPath = socketPath
        self.governor = governor
    }
    
    deinit {
        stop()
    }
    
    public func start() {
        guard !isRunning else { return }
        
        unlink(socketPath)
        
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            for (i, byte) in pathBytes.enumerated() {
                rawBuf[i] = UInt8(bitPattern: byte)
            }
        }
        
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            close(fd)
            return
        }
        
        chmod(socketPath, 0o666)
        
        self.serverFD = fd
        self.isRunning = true
        
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }
    
    public func stop() {
        isRunning = false
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        unlink(socketPath)
    }
    
    private func acceptLoop() {
        while isRunning && serverFD >= 0 {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverFD, sockPtr, &clientLen)
                }
            }
            if clientFD < 0 {
                if !isRunning { break }
                continue
            }
            handleClient(clientFD)
        }
    }
    
    private func handleClient(_ clientFD: Int32) {
        defer { close(clientFD) }
        
        // Prevent SIGPIPE if client disconnects early, and enforce 5s read/write timeouts
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        
        var euid: uid_t = 65534
        var egid: gid_t = 65534
        let credOK = (getpeereid(clientFD, &euid, &egid) == 0)
        let isAuthorized = credOK && isPeerAuthorized(euid: euid, egid: egid)
        
        var buffer = [UInt8](repeating: 0, count: 512)
        let bytesRead = read(clientFD, &buffer, buffer.count - 1)
        let request: String
        if bytesRead > 0 {
            request = String(decoding: buffer.prefix(bytesRead), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            request = "STATUS"
        }
        
        let response = processCommand(request, isAuthorized: isAuthorized)
        _ = response.withCString { cStr in
            write(clientFD, cStr, strlen(cStr))
        }
    }
    
    private func isPeerAuthorized(euid: uid_t, egid: gid_t) -> Bool {
        if euid == 0 { return true }
        var statBuf = stat()
        if stat("/dev/console", &statBuf) == 0 && statBuf.st_uid == euid {
            return true
        }
        if egid == 80 { return true }
        if let pwd = getpwuid(euid) {
            var numGroups: Int32 = 64
            var groups = [Int32](repeating: 0, count: 64)
            if getgrouplist(pwd.pointee.pw_name, Int32(pwd.pointee.pw_gid), &groups, &numGroups) == 0 {
                if groups.prefix(Int(numGroups)).contains(80) {
                    return true
                }
            }
        }
        return false
    }
    
    private func processCommand(_ commandLine: String, isAuthorized: Bool) -> String {
        guard let governor = governor else {
            return "{\"error\":\"Governor unavailable\"}\n"
        }
        
        let parts = commandLine.split(separator: " ").map(String.init)
        let cmd = (parts.first ?? "STATUS").uppercased()
        
        switch cmd {
        case "STATUS", "GET":
            let report = governor.getCombinedReport()
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                return json + "\n"
            }
            return "{\"error\":\"Serialization failed\"}\n"
            
        case "SET":
            guard isAuthorized else {
                return "{\"error\":\"Permission denied: console user, admin, or root (sudo) privileges required to control power\"}\n"
            }
            guard parts.count >= 2, let limit = Int(parts[1]), (30...100).contains(limit) else {
                return "{\"error\":\"Invalid limit: must be 30-100\"}\n"
            }
            var cfg = governor.config
            cfg.targetLimit = limit
            governor.updateConfig(cfg)
            return "{\"success\":true,\"target_limit\":\(limit)}\n"
            
        case "DRIFT", "DEADBAND":
            guard isAuthorized else {
                return "{\"error\":\"Permission denied: console user, admin, or root (sudo) privileges required to control power\"}\n"
            }
            guard parts.count >= 2 else {
                return "{\"error\":\"Usage: DRIFT <on|off> [margin]\"}\n"
            }
            let enabled = ["on", "true", "1"].contains(parts[1].lowercased())
            var margin = governor.config.driftMargin
            if parts.count >= 3, let m = Int(parts[2]), (1...10).contains(m) {
                margin = m
            }
            var cfg = governor.config
            cfg.driftEnabled = enabled
            cfg.driftMargin = margin
            governor.updateConfig(cfg)
            return "{\"success\":true,\"drift_enabled\":\(enabled),\"drift_margin\":\(margin),\"deadband_enabled\":\(enabled),\"deadband_delta\":\(margin)}\n"
            
        case "UPGRADE":
            var sourcePath = "/Applications/ChargePlan.app/Contents/Resources/chargeplan"
            if parts.count >= 2 {
                sourcePath = parts[1]
            }
            
            // Security verification: source must reside inside /Applications/ or caller must be authorized
            if !isAuthorized && !sourcePath.hasPrefix("/Applications/") {
                return "{\"error\":\"Permission denied: source binary must be inside /Applications/ or caller must be authorized\"}\n"
            }
            
            guard FileManager.default.isExecutableFile(atPath: sourcePath) else {
                return "{\"error\":\"Source binary does not exist or is not executable: \(sourcePath)\"}\n"
            }
            
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: sourcePath),
                  let fileSize = (attrs[.size] as? Int64) ?? (attrs[.size] as? Int).map(Int64.init),
                  fileSize > 50_000 else {
                return "{\"error\":\"Source binary is invalid or corrupt\"}\n"
            }
            
            let daemonDir = "/Library/Application Support/ChargePlan"
            let daemonBin = "\(daemonDir)/ChargePlanDaemon"
            let cliBin = "/usr/local/bin/chargeplan"
            
            try? FileManager.default.createDirectory(atPath: daemonDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: "/usr/local/bin", withIntermediateDirectories: true)
            
            // /usr/bin/install can leave a busy Mach-O untouched and still exit.
            // Fall back to copy-and-replace, and do not claim success unless the
            // destination is the new file.
            func installedSize(_ path: String) -> Int64? {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
                if let size = attrs[.size] as? Int64 { return size }
                if let size = attrs[.size] as? Int { return Int64(size) }
                if let size = attrs[.size] as? NSNumber { return size.int64Value }
                return nil
            }
            func installBinary(from source: String, to dest: String) -> Bool {
                let installer = Process()
                installer.executableURL = URL(fileURLWithPath: "/usr/bin/install")
                installer.arguments = ["-m", "755", source, dest]
                try? installer.run()
                installer.waitUntilExit()
                if installer.terminationStatus == 0, installedSize(dest) == fileSize {
                    return true
                }
                let tmp = dest + ".new"
                do {
                    if FileManager.default.fileExists(atPath: tmp) {
                        try FileManager.default.removeItem(atPath: tmp)
                    }
                    try FileManager.default.copyItem(atPath: source, toPath: tmp)
                    if FileManager.default.fileExists(atPath: dest) {
                        try FileManager.default.removeItem(atPath: dest)
                    }
                    try FileManager.default.moveItem(atPath: tmp, toPath: dest)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
                    return installedSize(dest) == fileSize
                } catch {
                    return false
                }
            }
            guard installBinary(from: sourcePath, to: daemonBin), installBinary(from: sourcePath, to: cliBin) else {
                return "{\"error\":\"Failed to install the new ChargePlan binary\"}\n"
            }
            
            for path in [daemonBin, cliBin] {
                let xattr = Process()
                xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                xattr.arguments = ["-cr", path]
                try? xattr.run()
                xattr.waitUntilExit()
                
                let cs = Process()
                cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                cs.arguments = ["--force", "--sign", "-", path]
                try? cs.run()
                cs.waitUntilExit()
            }
            
            // Allow socket response to flush before exit so launchd KeepAlive restarts with new binary
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                exit(0)
            }
            
            return "{\"success\":true,\"message\":\"ChargePlanDaemon & CLI updated. Restarting via launchd...\"}\n"
            
        case "INSTALL_APP":
            guard isAuthorized else {
                return "{\"error\":\"Permission denied: console user, admin, or root (sudo) privileges required to install app\"}\n"
            }
            guard parts.count >= 2 else {
                return "{\"error\":\"Usage: INSTALL_APP <source_app_path>\"}\n"
            }
            let sourceApp = parts.dropFirst().joined(separator: " ")
            guard FileManager.default.fileExists(atPath: sourceApp) && sourceApp.hasSuffix(".app") else {
                return "{\"error\":\"Invalid source app path: \(sourceApp)\"}\n"
            }
            let destApp = "/Applications/ChargePlan.app"
            let trashOld = "/tmp/ChargePlan-old-\(UUID().uuidString).app"
            
            // Move aside existing app
            if FileManager.default.fileExists(atPath: destApp) {
                let mvOld = Process()
                mvOld.executableURL = URL(fileURLWithPath: "/bin/mv")
                mvOld.arguments = [destApp, trashOld]
                try? mvOld.run()
                mvOld.waitUntilExit()
            }
            
            let cpProc = Process()
            cpProc.executableURL = URL(fileURLWithPath: "/bin/cp")
            cpProc.arguments = ["-R", sourceApp, destApp]
            try? cpProc.run()
            cpProc.waitUntilExit()
            
            _ = try? FileManager.default.removeItem(atPath: trashOld)
            _ = try? FileManager.default.removeItem(atPath: "/Applications/ChargeCap.app")
            
            // Fix ownership to the active console user so they own the app bundle
            let whoProc = Process()
            whoProc.executableURL = URL(fileURLWithPath: "/usr/bin/stat")
            whoProc.arguments = ["-f", "%Su", "/dev/console"]
            let whoPipe = Pipe()
            whoProc.standardOutput = whoPipe
            try? whoProc.run()
            whoProc.waitUntilExit()
            let whoData = whoPipe.fileHandleForReading.readDataToEndOfFile()
            let consoleUser = String(data: whoData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !consoleUser.isEmpty && consoleUser != "root" {
                let chownProc = Process()
                chownProc.executableURL = URL(fileURLWithPath: "/usr/sbin/chown")
                chownProc.arguments = ["-R", "\(consoleUser):admin", destApp]
                try? chownProc.run()
                chownProc.waitUntilExit()
            }
            
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-cr", destApp]
            try? xattr.run()
            xattr.waitUntilExit()
            
            let cs = Process()
            cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            cs.arguments = ["--force", "--deep", "--sign", "-", destApp]
            try? cs.run()
            cs.waitUntilExit()
            
            // Also install the bundled CLI and daemon binaries atomically
            let bundledCLI = "\(destApp)/Contents/Resources/chargeplan"
            if FileManager.default.isExecutableFile(atPath: bundledCLI) {
                let daemonDir = "/Library/Application Support/ChargePlan"
                let daemonBin = "\(daemonDir)/ChargePlanDaemon"
                let cliBin = "/usr/local/bin/chargeplan"
                
                let p1 = Process()
                p1.executableURL = URL(fileURLWithPath: "/usr/bin/install")
                p1.arguments = ["-m", "755", bundledCLI, daemonBin]
                try? p1.run()
                p1.waitUntilExit()
                
                let p2 = Process()
                p2.executableURL = URL(fileURLWithPath: "/usr/bin/install")
                p2.arguments = ["-m", "755", bundledCLI, cliBin]
                try? p2.run()
                p2.waitUntilExit()
                
                for path in [daemonBin, cliBin] {
                    let xa = Process()
                    xa.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                    xa.arguments = ["-cr", path]
                    try? xa.run()
                    xa.waitUntilExit()
                    
                    let sgn = Process()
                    sgn.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                    sgn.arguments = ["--force", "--sign", "-", path]
                    try? sgn.run()
                    sgn.waitUntilExit()
                }
                
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                    exit(0)
                }
            }
            
            return "{\"success\":true,\"message\":\"ChargePlan.app and daemon updated successfully.\"}\n"
            
        default:
            return "{\"error\":\"Unknown command. Supported: STATUS, SET <30-100>, DRIFT <on|off> [1-10], UPGRADE [path], INSTALL_APP <path>\"}\n"
        }
    }
}

public enum UnixSocketClient {
    public static func send(_ command: String, socketPath: String = UnixSocketServer.defaultSocketPath) -> String? {
        if let res = sendDirect(command, socketPath: socketPath) {
            return res
        }
        // Fallback to legacy socket during migration if default socket wasn't available
        if socketPath == UnixSocketServer.defaultSocketPath {
            return sendDirect(command, socketPath: UnixSocketServer.legacySocketPath)
        }
        return nil
    }

    /// True when the daemon accepted the command. Pretty-printed and compact JSON both count.
    public static func isSuccess(_ response: String?) -> Bool {
        guard let response,
              let data = response.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let ok = obj["success"] as? Bool {
            return ok
        }
        if let number = obj["success"] as? NSNumber {
            return number.boolValue
        }
        return false
    }
    
    private static func sendDirect(_ command: String, socketPath: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 8, tv_usec: 0)
        let timeoutLen = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutLen)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutLen)
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else { return nil }
        
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            for (i, byte) in pathBytes.enumerated() {
                rawBuf[i] = UInt8(bitPattern: byte)
            }
        }
        
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        
        let payload = command.hasSuffix("\n") ? command : (command + "\n")
        let written = payload.withCString { cStr in
            write(fd, cStr, strlen(cStr))
        }
        guard written > 0 else { return nil }
        _ = shutdown(fd, SHUT_WR)
        
        var output = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                output.append(buf, count: n)
                continue
            }
            if n < 0 && errno == EINTR { continue }
            break
        }
        return output.isEmpty ? nil : String(data: output, encoding: .utf8)
    }
}
