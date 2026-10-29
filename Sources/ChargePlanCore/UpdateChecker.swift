import Foundation
#if canImport(AppKit)
import AppKit
#endif

public let ChargePlanVersion = "0.4.11"

public struct ReleaseInfo: Codable, Equatable {
    public let version: String
    public let tagName: String
    public let title: String
    public let releaseNotes: String
    public let htmlUrl: String
    public let dmgUrl: String
    public let binaryUrl: String
    public let isNewer: Bool
    
    public init(
        version: String,
        tagName: String,
        title: String,
        releaseNotes: String,
        htmlUrl: String,
        dmgUrl: String,
        binaryUrl: String,
        isNewer: Bool
    ) {
        self.version = version
        self.tagName = tagName
        self.title = title
        self.releaseNotes = releaseNotes
        self.htmlUrl = htmlUrl
        self.dmgUrl = dmgUrl
        self.binaryUrl = binaryUrl
        self.isNewer = isNewer
    }
}

public enum UpdateError: LocalizedError {
    case networkError(String)
    case parsingError(String)
    case mountFailed(String)
    case missingAppBundle
    case copyFailed(String)
    case rootRequired
    case commandFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .networkError(let msg): return "Network error: \(msg)"
        case .parsingError(let msg): return "Failed to parse release information: \(msg)"
        case .mountFailed(let msg): return "Failed to mount update disk image: \(msg)"
        case .missingAppBundle: return "Downloaded disk image does not contain ChargePlan.app"
        case .copyFailed(let msg): return "Failed to install ChargePlan.app: \(msg)"
        case .rootRequired: return "Root privileges are required to update the daemon binary (run with sudo)"
        case .commandFailed(let msg): return "System command failed: \(msg)"
        }
    }
}

public final class UpdateChecker {
    private static let repoOwner = ChargePlanLayout.gitHubOwner
    private static let repoName = ChargePlanLayout.gitHubRepo
    
    private static let lastCheckKey = "io.github.wixe.chargeplan.lastUpdateCheck"
    private static let cachedReleaseKey = "io.github.wixe.chargeplan.cachedReleaseInfo"
    private static let legacyCacheKeys = [
        "com.wixe.chargeplan.cachedReleaseInfo",
        "com.wixe.chargecap.cachedReleaseInfo",
    ]
    private static let checkIntervalSeconds: TimeInterval = 86400 // 24 hours
    
    /// Newest cached release, including caches written under the old defaults keys.
    public static func cachedRelease() -> ReleaseInfo? {
        let defaults = UserDefaults.standard
        for key in [cachedReleaseKey] + legacyCacheKeys {
            if let data = defaults.data(forKey: key),
               let info = try? JSONDecoder().decode(ReleaseInfo.self, from: data) {
                return info
            }
        }
        return nil
    }
    
    /// Compares two semver version strings (e.g. "0.2.0" vs "v0.3.0").
    public static func compareVersion(_ v1: String, _ v2: String) -> ComparisonResult {
        let clean1 = v1.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))
        let clean2 = v2.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))
        
        let parts1 = clean1.split(separator: ".").compactMap { Int($0) }
        let parts2 = clean2.split(separator: ".").compactMap { Int($0) }
        
        let maxLen = max(parts1.count, parts2.count)
        for i in 0..<maxLen {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 < p2 { return .orderedAscending }
            if p1 > p2 { return .orderedDescending }
        }
        return .orderedSame
    }
    
    public static func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        return compareVersion(v1, v2) == .orderedDescending
    }
    
    public static func clearCache() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: lastCheckKey)
        defaults.removeObject(forKey: cachedReleaseKey)
        defaults.removeObject(forKey: "com.wixe.chargeplan.lastUpdateCheck")
        defaults.removeObject(forKey: "com.wixe.chargecap.lastUpdateCheck")
        for key in legacyCacheKeys {
            defaults.removeObject(forKey: key)
        }
    }
    
    /// Queries GitHub for the latest release or tags. Throttled to once every 24 hours unless `force: true`.
    public static func checkForUpdate(currentVersion: String = ChargePlanVersion, force: Bool = false) async -> ReleaseInfo? {
        let defaults = UserDefaults.standard
        
        if !force, let lastCheck = defaults.object(forKey: lastCheckKey) as? Date {
            if Date().timeIntervalSince(lastCheck) < checkIntervalSeconds {
                if let cachedData = defaults.data(forKey: cachedReleaseKey),
                   let cached = try? JSONDecoder().decode(ReleaseInfo.self, from: cachedData) {
                    let currentlyNewer = isVersion(cached.version, newerThan: currentVersion)
                    if cached.isNewer != currentlyNewer {
                        let updated = ReleaseInfo(
                            version: cached.version,
                            tagName: cached.tagName,
                            title: cached.title,
                            releaseNotes: cached.releaseNotes,
                            htmlUrl: cached.htmlUrl,
                            dmgUrl: cached.dmgUrl,
                            binaryUrl: cached.binaryUrl,
                            isNewer: currentlyNewer
                        )
                        persistCache(updated)
                        return updated
                    }
                    return cached
                }
                return nil
            }
        }
        
        // 1. First attempt: Query GitHub Releases (/releases/latest)
        if let info = await fetchLatestRelease(currentVersion: currentVersion) {
            persistCache(info)
            return info
        }
        
        // 2. Fallback attempt: Query GitHub Tags (/tags)
        if let info = await fetchLatestTag(currentVersion: currentVersion) {
            persistCache(info)
            return info
        }
        
        defaults.set(Date(), forKey: lastCheckKey)
        return nil
    }
    
    private static func persistCache(_ info: ReleaseInfo) {
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: lastCheckKey)
        if let data = try? JSONEncoder().encode(info) {
            defaults.set(data, forKey: cachedReleaseKey)
        }
    }
    
    private static func fetchLatestRelease(currentVersion: String) async -> ReleaseInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            return nil
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 4.0
        request.setValue("ChargePlan-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                return nil
            }
            
            let cleanVer = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))
            let isNewer = isVersion(cleanVer, newerThan: currentVersion)
            let title = json["name"] as? String ?? "ChargePlan \(tagName)"
            let body = json["body"] as? String ?? ""
            let htmlUrl = json["html_url"] as? String ?? "https://github.com/\(repoOwner)/\(repoName)/releases"
            
            var dmgUrl = "https://github.com/\(repoOwner)/\(repoName)/raw/main/dist/ChargePlan.dmg"
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String, name.hasSuffix(".dmg"),
                       let downloadUrl = asset["browser_download_url"] as? String {
                        dmgUrl = downloadUrl
                        break
                    }
                }
            }
            let binaryUrl = "https://raw.githubusercontent.com/\(repoOwner)/\(repoName)/main/bin/chargeplan"
            
            return ReleaseInfo(
                version: cleanVer,
                tagName: tagName,
                title: title,
                releaseNotes: body,
                htmlUrl: htmlUrl,
                dmgUrl: dmgUrl,
                binaryUrl: binaryUrl,
                isNewer: isNewer
            )
        } catch {
            return nil
        }
    }
    
    private static func fetchLatestTag(currentVersion: String) async -> ReleaseInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/tags") else {
            return nil
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 4.0
        request.setValue("ChargePlan-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            
            guard let tags = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = tags.first,
                  let tagName = first["name"] as? String else {
                return nil
            }
            
            let cleanVer = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))
            let isNewer = isVersion(cleanVer, newerThan: currentVersion)
            let title = "ChargePlan \(tagName)"
            let htmlUrl = "https://github.com/\(repoOwner)/\(repoName)/releases/tag/\(tagName)"
            let dmgUrl = "https://github.com/\(repoOwner)/\(repoName)/raw/main/dist/ChargePlan.dmg"
            let binaryUrl = "https://raw.githubusercontent.com/\(repoOwner)/\(repoName)/main/bin/chargeplan"
            
            return ReleaseInfo(
                version: cleanVer,
                tagName: tagName,
                title: title,
                releaseNotes: "Latest release available on GitHub.",
                htmlUrl: htmlUrl,
                dmgUrl: dmgUrl,
                binaryUrl: binaryUrl,
                isNewer: isNewer
            )
        } catch {
            return nil
        }
    }
    
    // MARK: - App Installation & Swap
    
    /// Downloads the DMG, extracts ChargePlan.app, replaces /Applications/ChargePlan.app, and optionally relaunches.
    public static func installAppUpdate(dmgUrl: URL, relaunch: Bool = true, progressHandler: @escaping (String) -> Void) async throws {
        progressHandler("Downloading update disk image…")
        
        let tempDmg = URL(fileURLWithPath: "/tmp/ChargePlan-update-\(UUID().uuidString).dmg")
        defer { try? FileManager.default.removeItem(at: tempDmg) }
        
        var request = URLRequest(url: dmgUrl)
        request.timeoutInterval = 30.0
        request.setValue("ChargePlan-Updater", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UpdateError.networkError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        
        try data.write(to: tempDmg)
        
        progressHandler("Mounting update disk image…")
        let mountDir = URL(fileURLWithPath: "/tmp/chargeplan-mnt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountDir, withIntermediateDirectories: true)
        defer {
            _ = runProcess("/usr/bin/hdiutil", ["detach", mountDir.path, "-quiet"])
            try? FileManager.default.removeItem(at: mountDir)
        }
        
        let attachResult = runProcess("/usr/bin/hdiutil", ["attach", tempDmg.path, "-mountpoint", mountDir.path, "-nobrowse", "-quiet"])
        guard attachResult.exitCode == 0 else {
            throw UpdateError.mountFailed(attachResult.output)
        }
        
        let sourceApp = mountDir.appendingPathComponent("ChargePlan.app")
        guard FileManager.default.fileExists(atPath: sourceApp.path) else {
            throw UpdateError.missingAppBundle
        }
        
        progressHandler("Installing \(ChargePlanLayout.appBundle)…")
        let destApp = URL(fileURLWithPath: ChargePlanLayout.appBundle)
        
        var installedViaDaemon = false
        var installSuccess = false
        var installErrorMsg = ""
        
        // Tier 1: Try user-level atomic move aside and copy
        let trashOld = URL(fileURLWithPath: "/tmp/ChargePlan-old-\(UUID().uuidString).app")
        var movedAside = false
        if FileManager.default.fileExists(atPath: destApp.path) {
            do {
                try FileManager.default.moveItem(at: destApp, to: trashOld)
                movedAside = true
            } catch {
                movedAside = false
            }
        } else {
            movedAside = true
        }
        
        if movedAside {
            let copyResult = runProcess("/bin/cp", ["-R", sourceApp.path, destApp.path])
            if copyResult.exitCode == 0 {
                installSuccess = true
                _ = try? FileManager.default.removeItem(at: trashOld)
            } else {
                installErrorMsg = copyResult.output
                // Restore original app if copy failed
                if FileManager.default.fileExists(atPath: trashOld.path) {
                    _ = try? FileManager.default.moveItem(at: trashOld, to: destApp)
                }
            }
        }
        
        // Tier 2: If Tier 1 failed (e.g. root-owned bundle or permission denied), ask the root daemon
        if !installSuccess {
            progressHandler("Requesting root daemon to install \(ChargePlanLayout.appBundle)…")
            if let resp = UnixSocketClient.send("INSTALL_APP \(sourceApp.path)"), UnixSocketClient.isSuccess(resp) {
                installSuccess = true
                installedViaDaemon = true
            } else {
                if installErrorMsg.isEmpty {
                    installErrorMsg = "Daemon IPC installation unsuccessful."
                }
            }
        }
        
        // Tier 3: If root daemon was not running or failed, fall back to AppleScript with administrator privileges
        if !installSuccess {
            progressHandler("Requesting administrator approval to install \(ChargePlanLayout.appBundle)…")
            let app = ChargePlanLayout.appBundle
            let adminScript = """
            do shell script "rm -rf '\(app)' && cp -R '\(sourceApp.path)' '\(app)' && chown -R $USER:admin '\(app)' && xattr -cr '\(app)' && codesign --force --deep --sign - '\(app)'" with administrator privileges
            """
            var scriptError: NSDictionary?
            #if canImport(AppKit)
            if let appleScript = NSAppleScript(source: adminScript) {
                _ = appleScript.executeAndReturnError(&scriptError)
                if scriptError == nil {
                    installSuccess = true
                } else if let msg = scriptError?["NSAppleScriptErrorMessage"] as? String {
                    installErrorMsg = msg
                }
            }
            #endif
        }
        
        guard installSuccess else {
            throw UpdateError.copyFailed(installErrorMsg)
        }
        
        SignedBinary.stripQuarantineAndSign(destApp.path, deep: true)
        
        // Detach volume
        _ = runProcess("/usr/bin/hdiutil", ["detach", mountDir.path, "-quiet"])
        
        // Automatically sync background daemon and CLI binaries if not already done by daemon INSTALL_APP
        if !installedViaDaemon {
            let bundledCLI = destApp.appendingPathComponent("Contents/Resources/chargeplan").path
            if FileManager.default.isExecutableFile(atPath: bundledCLI) {
                progressHandler("Automatically updating background daemon & CLI…")
                // 1. If daemon is running, trigger seamless zero-password socket UPGRADE
                if let resp = UnixSocketClient.send("UPGRADE \(bundledCLI)"), UnixSocketClient.isSuccess(resp) {
                    progressHandler("Background daemon updated and restarted.")
                } else if getuid() == 0 {
                    // 2. If running as root (e.g. CLI update), copy directly
                    try? FileManager.default.createDirectory(atPath: ChargePlanLayout.supportDirectory, withIntermediateDirectories: true)
                    try? FileManager.default.createDirectory(atPath: ChargePlanLayout.cliDirectory, withIntermediateDirectories: true)
                    _ = SignedBinary.install(from: bundledCLI, to: ChargePlanLayout.daemonBinary)
                    _ = SignedBinary.install(from: bundledCLI, to: ChargePlanLayout.cliBinary)
                    SignedBinary.stripQuarantineAndSign(ChargePlanLayout.daemonBinary)
                    SignedBinary.stripQuarantineAndSign(ChargePlanLayout.cliBinary)
                    _ = runProcess("/bin/launchctl", ["bootout", "system/\(ChargePlanLayout.previousDaemonLabel)"])
                    _ = runProcess("/bin/launchctl", ["bootout", "system/\(ChargePlanLayout.chargeCapDaemonLabel)"])
                    try? FileManager.default.removeItem(atPath: ChargePlanLayout.legacyDaemonPlists[0])
                    _ = runProcess("/bin/launchctl", ["kickstart", "-k", "system/\(ChargePlanLayout.daemonLabel)"])
                }
            }
        }
        
        // Clear cached update so newly launched app checks current status cleanly
        clearCache()
        
        if relaunch {
            progressHandler("Relaunching ChargePlan…")
            _ = Shell.run("/usr/bin/open", ["-n", destApp.path])
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                exit(0)
            }
        }
    }
    
    // MARK: - CLI & Daemon Installation
    
    /// Updates /usr/local/bin/chargeplan and reloads the root LaunchDaemon. Requires root privileges.
    public static func installCLIUpdate(binaryUrl: URL, progressHandler: @escaping (String) -> Void) async throws {
        guard getuid() == 0 else {
            throw UpdateError.rootRequired
        }
        
        progressHandler("Downloading latest chargeplan binary…")
        let tempBin = URL(fileURLWithPath: "/tmp/chargeplan-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempBin) }
        
        var request = URLRequest(url: binaryUrl)
        request.timeoutInterval = 30.0
        request.setValue("ChargePlan-Updater", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UpdateError.networkError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        try data.write(to: tempBin)
        
        progressHandler("Installing ChargePlanDaemon & CLI…")
        try? FileManager.default.createDirectory(atPath: ChargePlanLayout.supportDirectory, withIntermediateDirectories: true)
        _ = SignedBinary.install(from: tempBin.path, to: ChargePlanLayout.daemonBinary)
        SignedBinary.stripQuarantineAndSign(ChargePlanLayout.daemonBinary)
        _ = SignedBinary.install(from: tempBin.path, to: ChargePlanLayout.cliBinary)
        SignedBinary.stripQuarantineAndSign(ChargePlanLayout.cliBinary)
        
        progressHandler("Restarting LaunchDaemon…")
        _ = runProcess("/bin/launchctl", ["bootout", "system/\(ChargePlanLayout.previousDaemonLabel)"])
        _ = runProcess("/bin/launchctl", ["bootout", "system/\(ChargePlanLayout.chargeCapDaemonLabel)"])
        try? FileManager.default.removeItem(atPath: ChargePlanLayout.legacyDaemonPlists[0])
        try? FileManager.default.removeItem(atPath: ChargePlanLayout.legacyDaemonPlists[1])
        
        if FileManager.default.fileExists(atPath: ChargePlanLayout.daemonPlist) {
            _ = runProcess("/bin/launchctl", ["bootstrap", "system", ChargePlanLayout.daemonPlist])
            _ = runProcess("/bin/launchctl", ["kickstart", "-k", "system/\(ChargePlanLayout.daemonLabel)"])
        }
        
        // Clear cached update
        clearCache()
    }
    
    private static func runProcess(_ path: String, _ args: [String]) -> (exitCode: Int32, output: String) {
        Shell.run(path, args)
    }
}
