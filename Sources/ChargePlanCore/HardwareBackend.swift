import Foundation
import Darwin
import ObjectiveC
import OSLog

public enum ChargingMode: Equatable, Sendable {
    case directSMC
    case nativePowerUI
    case auxiliaryCLI(path: String)
    case simulation
}

public final class HardwareBackend {
    private var smcDriver: SMCDriver?
    private var activeMode: ChargingMode = .simulation
    private var currentLimit: Int = 50
    private var currentDelta: Int = 3
    private let logger = Logger(subsystem: "io.github.wixe.chargeplan", category: "HardwareBackend")

    // Cached PowerUISmartChargeClient instance (allocated once per backend lifetime)
    private var powerUIClient: AnyObject?
    private var powerUIClass: NSObject.Type?
    private var powerUIAvailableLimits: [Int] = []
    private var lastPublishedLimit: Int = -1
    private var lastPublishAt: Date = .distantPast
    private var powerdCache: (at: Date, text: String)?
    private let powerdLock = NSLock()
    private let backendLock = NSRecursiveLock()
    /// enableMCL: is the 80–100 XPC path. Calling it while a sub-80 ceiling is
    /// installed puts Apple's default back and the pack charges toward full.
    private var didArmMCL = false

    public init() {
        self.smcDriver = SMCDriver()
        self.setupPowerUI()
        self.activeMode = detectBestMode()
    }

    deinit {
        smcDriver?.close()
    }

    public var isNativePowerUI: Bool {
        activeMode == .nativePowerUI
    }

    private func setupPowerUI() {
        guard powerUIClient == nil else { return }
        autoreleasepool {
            guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
                  let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else {
                return
            }
            let allocSel = NSSelectorFromString("alloc")
            let initSel = NSSelectorFromString("initWithClientName:")
            let suppSel = NSSelectorFromString("isMCLSupported")
            let setSel = NSSelectorFromString("setMCLLimit:error:")
            let disSel = NSSelectorFromString("disableMCL:")
            let availSel = NSSelectorFromString("availableChargeLimitsWithError:")

            guard cls.responds(to: allocSel),
                  cls.instancesRespond(to: initSel),
                  cls.instancesRespond(to: suppSel),
                  cls.instancesRespond(to: setSel),
                  cls.instancesRespond(to: disSel),
                  cls.instancesRespond(to: availSel),
                  let allocMethod = class_getClassMethod(cls, allocSel),
                  let initMethod = class_getInstanceMethod(cls, initSel),
                  let suppMethod = class_getInstanceMethod(cls, suppSel) else {
                return
            }

            // `+alloc` returns +1; `-initWithClientName:` consumes `self` (+1) and returns +1.
            // Using direct C IMPs avoids calling `objc_retain` on an uninitialized `+alloc` instance.
            typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
            typealias InitFn = @convention(c) (UnsafeMutableRawPointer, Selector, NSString) -> Unmanaged<AnyObject>?
            guard let rawAllocated = unsafeBitCast(method_getImplementation(allocMethod), to: AllocFn.self)(cls, allocSel) else {
                return
            }
            guard let initialized = unsafeBitCast(method_getImplementation(initMethod), to: InitFn.self)(
                rawAllocated.toOpaque(),
                initSel,
                "chargeplan" as NSString
            ) else {
                return
            }
            let client = initialized.takeRetainedValue()

            typealias BoolFn = @convention(c) (AnyObject, Selector) -> Bool
            let isSupported = unsafeBitCast(method_getImplementation(suppMethod), to: BoolFn.self)(client, suppSel)
            guard isSupported else { return }

            self.powerUIClass = cls
            self.powerUIClient = client
            self.powerUIAvailableLimits = [80, 85, 90, 95, 100]

            if geteuid() == 0, let availMethod = class_getInstanceMethod(cls, availSel) {
                // ObjC `NSError **` is `__autoreleasing` (+0); use `Unmanaged<NSError>?` so Swift ARC
                // never emits an extra `objc_release` when the surrounding `autoreleasepool` drains.
                typealias AvailFn = @convention(c) (
                    AnyObject,
                    Selector,
                    UnsafeMutablePointer<Unmanaged<NSError>?>?
                ) -> Unmanaged<AnyObject>?
                var err: Unmanaged<NSError>? = nil
                if let rawArr = unsafeBitCast(method_getImplementation(availMethod), to: AvailFn.self)(client, availSel, &err),
                   err == nil,
                   let arr = rawArr.takeUnretainedValue() as? [NSNumber],
                   !arr.isEmpty {
                    self.powerUIAvailableLimits = arr.map { $0.intValue }.sorted()
                }
            }
        }
    }

    private func hasDirectSMCChargingKeys(_ smc: SMCDriver) -> Bool {
        if smc.getKeyInfo("bfF0") != nil && smc.getKeyInfo("bfD0") != nil && smc.getKeyInfo("bfE0") != nil {
            return true
        }
        if smc.getKeyInfo("CHTE") != nil {
            return true
        }
        if smc.getKeyInfo("CH0B") != nil {
            return true
        }
        if smc.getKeyInfo("BCLM") != nil {
            return true
        }
        return false
    }

    private func detectBestMode() -> ChargingMode {
        if let smc = smcDriver, hasDirectSMCChargingKeys(smc) {
            return .directSMC
        }
        if powerUIClient != nil {
            return .nativePowerUI
        }
        let possibleCLIs = [
            "/usr/local/bin/smc",
            "/opt/homebrew/bin/smc",
            "/opt/homebrew/bin/batt",
            "/usr/local/bin/batt"
        ]
        for path in possibleCLIs {
            if FileManager.default.isExecutableFile(atPath: path) {
                return .auxiliaryCLI(path: path)
            }
        }
        return .simulation
    }

    public var modeName: String {
        switch activeMode {
        case .directSMC:
            return "Direct AppleSMC Driver (AC Pass-Through)"
        case .nativePowerUI:
            return "macOS Native PowerUI (AC Pass-Through)"
        case .auxiliaryCLI(let path):
            return "Auxiliary Engine (\(path))"
        case .simulation:
            return "Simulation (Driver Emulation)"
        }
    }

    public func setChargingInhibited(_ inhibit: Bool) -> Bool {
        backendLock.lock()
        defer { backendLock.unlock() }
        return autoreleasepool {
            switch activeMode {
            case .directSMC:
                guard let smc = smcDriver else { return false }

                if smc.getKeyInfo("bfF0") != nil && smc.getKeyInfo("bfD0") != nil && smc.getKeyInfo("bfE0") != nil {
                    if inhibit {
                        let upper = UInt32(max(30, min(100, currentLimit)))
                        let lower = UInt32(max(25, Int(upper) - max(1, currentDelta)))
                        _ = smc.writeByte("bfF0", value: 0x00)
                        let sUpper = smc.writeUInt32LE("bfD0", value: upper)
                        let sLower = smc.writeUInt32LE("bfE0", value: lower)
                        let sAct = smc.writeByte("bfF0", value: 0x02)
                        return sUpper && sLower && sAct
                    } else {
                        return smc.writeByte("bfF0", value: 0x00)
                    }
                }

                if smc.getKeyInfo("CHTE") != nil {
                    let bytes: [UInt8] = inhibit ? [0x01, 0x00, 0x00, 0x00] : [0x00, 0x00, 0x00, 0x00]
                    return smc.writeBytes("CHTE", bytes: bytes)
                }

                if smc.getKeyInfo("CH0B") != nil {
                    let val: UInt8 = inhibit ? 0x02 : 0x00
                    let s1 = smc.writeByte("CH0B", value: val)
                    if smc.getKeyInfo("CH0C") != nil {
                        _ = smc.writeByte("CH0C", value: val)
                    }
                    return s1
                }

                return false

            case .nativePowerUI:
                return inhibit ? applyPowerUILimit(currentLimit, force: false) : disablePowerUILimit()

            case .auxiliaryCLI(let path):
                let args: [String]
                if path.contains("batt") {
                    args = inhibit ? ["limit", "\(max(30, min(100, currentLimit)))"] : ["disable"]
                } else {
                    args = ["-k", "CH0B", "-w", inhibit ? "02" : "00"]
                }
                return Self.runCommand(path, args).status == 0

            case .simulation:
                return true
            }
        }
    }

    public func setChargeLimitPercentage(_ limit: Int, delta: Int = 3, force: Bool = false) -> Bool {
        backendLock.lock()
        defer { backendLock.unlock() }
        let clamped = max(30, min(100, limit))
        self.currentLimit = clamped
        self.currentDelta = max(1, delta)

        return autoreleasepool {
            switch activeMode {
            case .directSMC:
                guard let smc = smcDriver else { return false }
                if smc.getKeyInfo("bfF0") != nil && smc.getKeyInfo("bfD0") != nil && smc.getKeyInfo("bfE0") != nil {
                    if clamped >= 100 {
                        return smc.writeByte("bfF0", value: 0x00)
                    }
                    let upper = UInt32(clamped)
                    let lower = UInt32(max(25, clamped - self.currentDelta))
                    _ = smc.writeByte("bfF0", value: 0x00)
                    let sUpper = smc.writeUInt32LE("bfD0", value: upper)
                    let sLower = smc.writeUInt32LE("bfE0", value: lower)
                    let sAct = smc.writeByte("bfF0", value: 0x02)
                    return sUpper && sLower && sAct
                }
                if smc.getKeyInfo("BCLM") != nil {
                    return smc.writeByte("BCLM", value: UInt8(clamped))
                }
                return true

            case .nativePowerUI:
                if clamped >= 100 {
                    return disablePowerUILimit()
                }
                return applyPowerUILimit(clamped, force: force)

            case .auxiliaryCLI(let path):
                if path.contains("batt") {
                    let args = clamped >= 100 ? ["disable"] : ["limit", "\(clamped)"]
                    return Self.runCommand(path, args).status == 0
                }
                return true

            case .simulation:
                return true
            }
        }
    }

    /// Safely invokes an Objective-C method taking `(NSError * __autoreleasing *)` inside any `autoreleasepool`
    /// without allowing Swift ARC to treat the `+0` autoreleased out-parameter as `+1` `__strong`.
    internal static func invokeObjCBoolWithAutoreleasingError(
        client: AnyObject,
        cls: AnyClass,
        selector: Selector
    ) -> (ok: Bool, hadError: Bool)? {
        guard let method = class_getInstanceMethod(cls, selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Bool
        var err: Unmanaged<NSError>? = nil
        let ok = unsafeBitCast(method_getImplementation(method), to: Fn.self)(client, selector, &err)
        return (ok, err != nil)
    }

    private func getCurrentPowerUILimit() -> (enabled: Bool, limit: Int)? {
        guard let cls = powerUIClass, let client = powerUIClient else { return nil }
        let getSel = NSSelectorFromString("getMCLLimitWithError:")
        let enSel = NSSelectorFromString("isMCLCurrentlyEnabled:")
        guard client.responds(to: getSel),
              client.responds(to: enSel),
              let getMethod = class_getInstanceMethod(cls, getSel),
              let enMethod = class_getInstanceMethod(cls, enSel) else {
            return nil
        }
        typealias GetLimitFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> UInt8
        typealias IsEnabledFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> UInt64
        var err1: Unmanaged<NSError>? = nil
        var err2: Unmanaged<NSError>? = nil
        let limit = unsafeBitCast(method_getImplementation(getMethod), to: GetLimitFn.self)(client, getSel, &err1)
        let enabled = unsafeBitCast(method_getImplementation(enMethod), to: IsEnabledFn.self)(client, enSel, &err2)
        if err1 != nil || err2 != nil {
            return nil
        }
        return (enabled != 0, Int(limit))
    }

    private func setDirectXPCMCLLimit(_ target: UInt8) -> Bool {
        guard let cls = powerUIClass, let client = powerUIClient else { return false }
        let setSel = NSSelectorFromString("setMCLLimit:error:")
        guard let method = class_getInstanceMethod(cls, setSel) else { return false }
        typealias SetFn = @convention(c) (AnyObject, Selector, UInt8, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Bool
        var err: Unmanaged<NSError>? = nil
        return unsafeBitCast(method_getImplementation(method), to: SetFn.self)(client, setSel, target, &err)
    }

    /// Snapshot of powerd's active non-terminated SoC ceiling and explicit-none flag.
    public func powerdSnapshot() -> PowerdSnapshot {
        let text = powerdLimitText()
        let activeLimits = Self.parsePowerdSocLimits(text)
        let enforced = activeLimits.max()
        let explicitNone: Bool
        if !activeLimits.isEmpty {
            explicitNone = false
        } else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                explicitNone = false
            } else {
                let allRecords = Self.parsePowerdSocLimitRecords(text)
                explicitNone = (!allRecords.isEmpty && allRecords.allSatisfy(\.terminated))
                    || text.contains("No battery level limits set")
            }
        }
        return PowerdSnapshot(enforcedSoc: enforced, reportedNoCeiling: explicitNone)
    }

    /// Highest active (non-terminated) `chargeSocLimitSoc` registered with powerd, if any.
    public func powerdSocLimit() -> Int? {
        Self.parsePowerdSocLimits(powerdLimitText()).max()
    }

    /// True only when `pmset` itself reported that no active ceiling is registered.
    public func powerdReportedNoCeiling() -> Bool {
        powerdSnapshot().reportedNoCeiling
    }

    public func powerUIInterfaceState() -> (state: Int, limit: Int)? {
        guard let cls = powerUIClass, let client = powerUIClient else { return nil }
        let sel = NSSelectorFromString("smartChargingUIState:chargeLimit:chargingOverrideAllowed:withError:")
        guard let method = class_getInstanceMethod(cls, sel) else { return nil }
        typealias Fn = @convention(c) (
            AnyObject, Selector,
            UnsafeMutablePointer<UInt64>,
            UnsafeMutablePointer<UInt64>,
            UnsafeMutablePointer<ObjCBool>,
            UnsafeMutablePointer<Unmanaged<NSError>?>?
        ) -> Bool
        var state: UInt64 = 0
        var limit: UInt64 = 0
        var allow = ObjCBool(false)
        var err: Unmanaged<NSError>? = nil
        let ok = unsafeBitCast(method_getImplementation(method), to: Fn.self)(client, sel, &state, &limit, &allow, &err)
        guard ok, err == nil, state <= 64, limit <= 100 else { return nil }
        return (Int(state), Int(limit))
    }

    public func powerdInhibitsFullCharge(at soc: Int) -> Bool {
        Self.parsePowerdSocLimitRecords(powerdLimitText()).contains {
            !$0.terminated && $0.soc == soc && $0.noChargeToFull
        }
    }

    private func powerdLimitText() -> String {
        powerdLock.lock()
        if let cache = powerdCache, Date().timeIntervalSince(cache.at) < 2.5 {
            let text = cache.text
            powerdLock.unlock()
            return text
        }
        powerdLock.unlock()

        let text = autoreleasepool {
            Self.readPmsetBattlimit()
        }
        powerdLock.lock()
        powerdCache = (Date(), text)
        powerdLock.unlock()
        return text
    }

    private func invalidatePowerdCache() {
        powerdLock.lock()
        powerdCache = nil
        powerdLock.unlock()
    }

    public struct PowerdSocLimit: Equatable, Sendable {
        public let soc: Int
        public let noChargeToFull: Bool
        public let terminated: Bool
    }

    /// Pure zero-regex parser for `pmset -g battlimit` records.
    public static func parsePowerdSocLimitRecords(_ text: String) -> [PowerdSocLimit] {
        var records: [PowerdSocLimit] = []
        var depth = 0
        var bodyStart: String.Index?
        for index in text.indices {
            let character = text[index]
            if character == "{" {
                if depth == 0 { bodyStart = text.index(after: index) }
                depth += 1
            } else if character == "}" && depth > 0 {
                depth -= 1
                if depth == 0, let start = bodyStart {
                    records.append(contentsOf: limitRecord(in: text[start..<index]))
                    bodyStart = nil
                }
            }
        }
        if records.isEmpty {
            records.append(contentsOf: limitRecord(in: text[...]))
        }
        return records
    }

    /// Active (non-terminated) SoC limits advertised by powerd.
    /// Filtering out `Terminated = 1` entries prevents stale Optimized Battery Charging
    /// records (e.g. 80%) from masking an active sub-80 manual ceiling.
    public static func parsePowerdSocLimits(_ text: String) -> [Int] {
        parsePowerdSocLimitRecords(text)
            .filter { !$0.terminated }
            .map(\.soc)
    }

    private static func limitRecord(in body: Substring) -> [PowerdSocLimit] {
        guard let soc = firstIntAssignment(in: body, key: "chargeSocLimitSoc"), (1...100).contains(soc) else {
            return []
        }
        let noChargeToFull = firstIntAssignment(in: body, key: "chargeSocLimitNoChargeToFull") == 1
        let terminated = firstIntAssignment(in: body, key: "Terminated") == 1
        return [PowerdSocLimit(soc: soc, noChargeToFull: noChargeToFull, terminated: terminated)]
    }

    /// Pure UTF-8 byte scanner for `<word-boundary><key>\s*=\s*(\d{1,3})\b` with zero regex or heap allocations.
    private static func firstIntAssignment(in body: Substring, key: StaticString) -> Int? {
        let utf8 = body.utf8
        let keyCount = key.utf8CodeUnitCount
        guard utf8.count > keyCount else { return nil }

        @inline(__always)
        func isIdent(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F
        }
        @inline(__always)
        func isSpace(_ b: UInt8) -> Bool {
            b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
        }

        return key.withUTF8Buffer { keyBuf in
            var idx = utf8.startIndex
            var prevByte: UInt8? = nil

            while idx < utf8.endIndex {
                let b = utf8[idx]
                if b == keyBuf[0], (prevByte == nil || !isIdent(prevByte!)) {
                    var scan = idx
                    var matchedKey = true
                    for k in 0..<keyCount {
                        guard scan < utf8.endIndex, utf8[scan] == keyBuf[k] else {
                            matchedKey = false
                            break
                        }
                        scan = utf8.index(after: scan)
                    }
                    if matchedKey, (scan == utf8.endIndex || !isIdent(utf8[scan])) {
                        while scan < utf8.endIndex && isSpace(utf8[scan]) {
                            scan = utf8.index(after: scan)
                        }
                        if scan < utf8.endIndex && utf8[scan] == 0x3D { // '='
                            scan = utf8.index(after: scan)
                            while scan < utf8.endIndex && isSpace(utf8[scan]) {
                                scan = utf8.index(after: scan)
                            }
                            var value = 0
                            var digits = 0
                            while scan < utf8.endIndex, utf8[scan] >= 0x30, utf8[scan] <= 0x39, digits < 4 {
                                value = value * 10 + Int(utf8[scan] - 0x30)
                                digits += 1
                                scan = utf8.index(after: scan)
                            }
                            if (1...3).contains(digits) {
                                return value
                            }
                        }
                    }
                }
                prevByte = b
                idx = utf8.index(after: idx)
            }
            return nil
        }
    }

    private static func readPmsetBattlimit() -> String {
        let direct = runCommand("/usr/bin/pmset", ["-g", "battlimit"])
        if !parsePowerdSocLimits(direct.output).isEmpty {
            return direct.output
        }
        if let uid = consoleUserID() {
            let bounced = runCommand("/bin/launchctl", ["asuser", String(uid), "/usr/bin/pmset", "-g", "battlimit"])
            if !parsePowerdSocLimits(bounced.output).isEmpty {
                return bounced.output
            }
            logBattlimitRead(direct: direct, bounced: bounced, uid: uid)
            return longerBattlimitText(direct.output, bounced.output)
        }
        logBattlimitRead(direct: direct, bounced: nil, uid: nil)
        return direct.output
    }

    private static func longerBattlimitText(_ first: String, _ second: String) -> String {
        second.count > first.count ? second : first
    }

    private static let battlimitLogLock = NSLock()
    private static var lastBattlimitLog = ""
    private static var lastBattlimitLogAt = Date.distantPast

    private static func logBattlimitRead(
        direct: (status: Int32, output: String),
        bounced: (status: Int32, output: String)?,
        uid: uid_t?
    ) {
        // Do not spam logs when powerd explicitly reports "No battery level limits set" (e.g. on battery or 100% cap)
        if direct.output.contains("No battery level limits set") || bounced?.output.contains("No battery level limits set") == true {
            return
        }
        func flat(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "empty" }
            return String(trimmed.prefix(180)).replacingOccurrences(of: "\n", with: " ")
        }
        let bouncedText = bounced.map { " asuser=\($0.status):\(flat($0.output))" } ?? ""
        let uidText = uid.map(String.init) ?? "none"
        let line = "pmset battlimit unreadable direct=\(direct.status):\(flat(direct.output))\(bouncedText) console=\(uidText)\n"
        battlimitLogLock.lock()
        defer { battlimitLogLock.unlock() }
        let now = Date()
        if line == lastBattlimitLog && now.timeIntervalSince(lastBattlimitLogAt) < 600 {
            return
        }
        lastBattlimitLog = line
        lastBattlimitLogAt = now
        fputs(line, stdout)
        fflush(stdout)
    }

    private static func consoleUserID() -> uid_t? {
        var info = stat()
        guard stat("/dev/console", &info) == 0 else { return nil }
        let uid = info.st_uid
        guard uid != 0 else { return nil }
        return uid
    }

    @discardableResult
    private static func runCommand(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        var pipes = [Int32](repeating: -1, count: 2)
        guard pipe(&pipes) == 0 else { return (-1, "") }
        let readFD = pipes[0]
        let writeFD = pipes[1]
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            close(readFD)
            close(writeFD)
            return (-1, "")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_addclose(&actions, writeFD)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)

        var spawnAttr: posix_spawnattr_t?
        let hasAttr = (posix_spawnattr_init(&spawnAttr) == 0)
        if hasAttr {
            posix_spawnattr_setflags(&spawnAttr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        }
        defer {
            if hasAttr {
                posix_spawnattr_destroy(&spawnAttr)
            }
        }

        let argvPointers: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        defer { argvPointers.forEach { free($0) } }

        var pid: pid_t = 0
        let spawned: Int32 = argvPointers.withUnsafeBufferPointer { buffer in
            if hasAttr {
                return posix_spawn(&pid, path, &actions, &spawnAttr, buffer.baseAddress, environ)
            }
            return posix_spawn(&pid, path, &actions, nil, buffer.baseAddress, environ)
        }
        close(writeFD)
        guard spawned == 0 else {
            close(readFD)
            return (spawned, "")
        }

        let data = readUntilEOF(readFD, timeoutSeconds: 4)
        close(readFD)

        var status: Int32 = 0
        var waited = waitpid(pid, &status, WNOHANG)
        if waited == 0 {
            // Give fast-exiting child up to 50ms to reap cleanly before SIGKILL
            for _ in 0..<10 {
                usleep(5_000)
                waited = waitpid(pid, &status, WNOHANG)
                if waited != 0 { break }
            }
            if waited == 0 {
                kill(pid, SIGKILL)
                waited = waitpid(pid, &status, 0)
            }
        }
        let code: Int32 = (waited > 0 && (status & 0o177) == 0) ? (status >> 8) & 0xff : -1
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return (code, text)
    }

    private static func readUntilEOF(_ fd: Int32, timeoutSeconds: TimeInterval) -> Data {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remainingMS = Int32(max(1, min(deadline.timeIntervalSinceNow * 1000, 4000)))
            let ready = poll(&pollFD, 1, remainingMS)
            if ready == 0 { break }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                continue
            }
            if count == 0 { break }
            if errno == EINTR || errno == EAGAIN { continue }
            break
        }
        return data
    }

    private func applyPowerUILimit(_ requested: Int, force: Bool) -> Bool {
        let clamped = max(20, min(100, requested))
        if !force, clamped == lastPublishedLimit, Date().timeIntervalSince(lastPublishAt) < 15 {
            return true
        }
        invalidatePowerdCache()

        if clamped >= 80 {
            if !powerUIAvailableLimits.isEmpty && !powerUIAvailableLimits.contains(clamped) {
                logger.info("Charge limit \(clamped, privacy: .public) is between the advertised steps; sending it directly")
            }
            if getCurrentPowerUILimit()?.enabled != true {
                _ = enableMCL()
                Thread.sleep(forTimeInterval: 0.2)
            }
            let ok = setDirectXPCMCLLimit(UInt8(clamped))
            if ok {
                lastPublishedLimit = clamped
                lastPublishAt = Date()
            } else {
                logger.error("setMCLLimit \(clamped, privacy: .public) was rejected")
            }
            return ok
        }

        guard geteuid() == 0 else {
            logger.error("A charge limit below 80% has to be published by the root daemon")
            return false
        }

        if !didArmMCL {
            if getCurrentPowerUILimit()?.enabled != true {
                _ = enableMCL()
                Thread.sleep(forTimeInterval: 0.2)
            }
            didArmMCL = true
        }
        guard publishTopOffPreference(limit: clamped, enabled: true) else {
            logger.error("Failed to write mclLimitValue \(clamped, privacy: .public)")
            return false
        }
        let valueChanged = lastPublishedLimit != clamped
        notifyChargeLimitChanged(restartAgent: valueChanged)
        lastPublishedLimit = clamped
        lastPublishAt = Date()
        logger.info("Published sub-80 charge ceiling \(clamped, privacy: .public) to powerd")
        return true
    }

    private func enableMCL() -> Bool {
        guard let cls = powerUIClass, let client = powerUIClient else { return false }
        let sel = NSSelectorFromString("enableMCL:")
        return Self.invokeObjCBoolWithAutoreleasingError(client: client, cls: cls, selector: sel)?.ok ?? false
    }

    private func publishTopOffPreference(limit: Int, enabled: Bool) -> Bool {
        let domain = "com.apple.smartcharging.topoffprotection" as CFString
        let user = kCFPreferencesCurrentUser
        let host = kCFPreferencesAnyHost
        func put(_ key: String, _ value: CFPropertyList) {
            CFPreferencesSetValue(key as CFString, value, domain, user, host)
        }
        if enabled {
            let number = NSNumber(value: limit)
            put("mclLimitValue", number)
            put("mclTargetSoC", number)
            put("MCLSavedTargetSoC", number)
            put("MCLFeatureState", NSNumber(value: 1))
            put("enabled", kCFBooleanTrue)
        } else {
            put("MCLFeatureState", NSNumber(value: 0))
            put("enabled", kCFBooleanFalse)
            put("mclLimitValue", NSNumber(value: 100))
        }
        let synced = CFPreferencesSynchronize(domain, user, host)
        publishConsoleUserTopOff(limit: limit, enabled: enabled)
        return synced
    }

    private func publishConsoleUserTopOff(limit: Int, enabled: Bool) {
        guard let uid = Self.consoleUserID(), uid != 0 else { return }
        let domain = "com.apple.smartcharging.topoffprotection"
        func write(_ key: String, _ type: String, _ value: String) {
            _ = Self.runCommand("/bin/launchctl", [
                "asuser", String(uid),
                "/usr/bin/defaults", "write", domain, key, type, value
            ])
        }
        if enabled {
            write("mclLimitValue", "-int", "\(limit)")
            write("mclTargetSoC", "-int", "\(limit)")
            write("MCLSavedTargetSoC", "-int", "\(limit)")
            write("MCLFeatureState", "-int", "1")
            write("enabled", "-bool", "true")
        } else {
            write("MCLFeatureState", "-int", "0")
            write("enabled", "-bool", "false")
            write("mclLimitValue", "-int", "100")
        }
    }

    private func notifyChargeLimitChanged(restartAgent: Bool) {
        _ = Self.runCommand("/usr/bin/notifyutil", ["-p", "com.apple.smartcharging.defaultschanged"])

        guard restartAgent, geteuid() == 0 else { return }
        // PowerUIAgent reloads preferences in-place on SIGHUP; existing XPC client remains valid.
        _ = Self.runCommand("/usr/bin/killall", ["-HUP", "PowerUIAgent"])
        Thread.sleep(forTimeInterval: 0.25)
        invalidatePowerdCache()
    }

    private func disablePowerUILimit() -> Bool {
        if let current = getCurrentPowerUILimit(), !current.enabled {
            return true
        }
        guard let cls = powerUIClass, let client = powerUIClient else { return false }
        let disSel = NSSelectorFromString("disableMCL:")
        guard let invoked = Self.invokeObjCBoolWithAutoreleasingError(client: client, cls: cls, selector: disSel) else {
            return false
        }
        let res = invoked.ok
        if res, geteuid() == 0 {
            _ = publishTopOffPreference(limit: 100, enabled: false)
            notifyChargeLimitChanged(restartAgent: false)
            lastPublishedLimit = 100
            lastPublishAt = Date()
        }
        return res
    }
}
