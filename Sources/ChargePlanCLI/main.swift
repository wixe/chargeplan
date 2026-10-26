import Foundation
import ChargePlanCore

let VERSION = ChargePlanVersion

func printHelp() {
    print("""
    ⚡ ChargePlan — Intelligent, Lightweight Battery & Power Management for macOS
    Version \(VERSION) (Apple Silicon M-Series)
    Website: \(ChargePlanLayout.projectURL.absoluteString)
    
    USAGE:
      chargeplan <command> [options]
    
    COMMANDS:
      status [--json]           Display battery health, power telemetry, and governor status
      set <limit>               Set target charge limit (e.g. 50, 80)
      drift <on|off> [margin]   Configure drift margin (e.g. drift on 3)
      daemon                    Run the power governor in the foreground
      install                   Install background system service (keeps limit active when sleeping or logged out)
      uninstall                 Remove background system service
      update [--check|--force]  Check GitHub and automatically upgrade binary and .app
      version                   Print version information
    
    EXAMPLES:
      chargeplan status
      sudo chargeplan set 50
      sudo chargeplan drift on 3
      sudo chargeplan install
      sudo chargeplan update
    """)
}

var ipcServer: UnixSocketServer? = nil

func handleStatus(jsonOutput: Bool) {
    if jsonOutput {
        if let liveJson = UnixSocketClient.send("STATUS") {
            print(liveJson.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        let cfg = ConfigManager.shared.load()
        let monitor = BatteryMonitor()
        let hardware = HardwareBackend()
        var state = GovernorState.initial
        state.modeDescription = "Offline (Run 'sudo chargeplan install')"
        state.lastActionReason = "Daemon not running"
        let report = ChargeReport.dictionary(
            battery: monitor.getCurrentStatus(),
            config: cfg,
            state: state,
            backend: hardware.modeName,
            enforcedSoc: hardware.powerdSocLimit() ?? -1
        )
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
        return
    }
    
    let monitor = BatteryMonitor()
    let status = monitor.getCurrentStatus()
    let cfg = ConfigManager.shared.load()
    let hw = HardwareBackend()
    
    var governorMode = "Offline (Run 'sudo chargeplan install')"
    var ceilingLine = ""
    if let liveJson = UnixSocketClient.send("STATUS"),
       let data = liveJson.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let gov = obj["governor"] as? [String: Any] {
        if let mode = gov["mode"] as? String {
            governorMode = mode
        }
        if let soc = gov["enforced_soc"] as? Int, soc > 0 {
            ceilingLine = "\n  powerd Ceiling:     \(soc)%"
        }
    }
    
    let isAC = status.isACConnected
    let chargingStr = status.isCharging ? "⚡ Charging" : (isAC ? "🔌 AC Connected (Not Charging)" : "🔋 Discharging")
    let wattageStr = String(format: "%.2fW", abs(status.wattageW))
    let healthBarLength = 20
    let filledHealth = Int((status.healthPercent / 100.0) * Double(healthBarLength))
    let bar = String(repeating: "█", count: max(0, min(healthBarLength, filledHealth))) +
              String(repeating: "░", count: max(0, healthBarLength - filledHealth))
    
    var cellDetails = ""
    if !status.cellVoltagesMV.isEmpty {
        let cellsFormatted = status.cellVoltagesMV.enumerated().map { "Cell \($0.offset + 1): \($0.element) mV" }.joined(separator: "  •  ")
        let delta = status.cellImbalanceMV != nil ? " (Δ \(status.cellImbalanceMV!) mV)" : ""
        cellDetails = "\n  Cell Voltages:      \(cellsFormatted)\(delta)"
    }
    var tempDetails = ""
    if let t = status.temperatureC {
        let fahrenheit = t * 9.0 / 5.0 + 32.0
        tempDetails = String(format: "\n  Battery Temp:       %.1f°C (%.1f°F)", t, fahrenheit)
    }
    
    print("""
    ========================================================================
    ⚡ CHARGEPLAN POWER TELEMETRY & CONTROLLER
    ========================================================================
      Battery Level:      \(String(format: "%.2f%%", status.exactPercent)) (\(chargingStr))
      Target Limit:       \(cfg.targetLimit)% \(cfg.driftEnabled ? "(Drift -\(cfg.driftMargin)%)" : "(Strict)")
      Control Mode:       \(governorMode)\(ceilingLine)
      Health Condition:   [\(bar)] \(status.healthPercent)%
      Cycle Count:        \(status.cycleCount) cycles
      Voltage & Current:  \(status.voltageMV) mV  •  \(status.amperageMA) mA (\(wattageStr))
      Hardware Capacity:  \(status.remainingCapacityMAh > 0 ? "\(status.remainingCapacityMAh) / " : "")\(status.fullChargeCapacityMAh) / \(status.designCapacityMAh) mAh\(cellDetails)\(tempDetails)
      Thermal State:      \(status.thermalState)
      Hardware Backend:   \(hw.modeName)
      Serial Number:      \(status.serialNumber)
      Icon Legend:        ⚡ Charging  •  🔌 AC Pass-Through (Hold)  •  🔋 On Battery
    ========================================================================
    """)
    
    if let cached = UpdateChecker.cachedRelease(),
       UpdateChecker.isVersion(cached.version, newerThan: ChargePlanVersion) {
        print("💡 Update available: \(cached.tagName) — Run 'sudo chargeplan update' to upgrade.\n")
    }
}

func handleSet(args: [String]) {
    guard let first = args.first, let val = Int(first), (30...100).contains(val) else {
        print("❌ Error: Please specify a valid limit between 30 and 100 (e.g. 'chargeplan set 50')")
        exit(1)
    }
    
    if daemonAccepted(
        "SET \(val)",
        denied: "❌ Permission denied by daemon. Please run with sudo: sudo chargeplan set \(val)",
        offline: "❌ Power control requires root privileges (or start background daemon with 'sudo chargeplan install'):\n   sudo chargeplan set \(val)"
    ) {
        print("✅ ChargePlan daemon updated via socket: target limit is now \(val)%.")
        return
    }
    
    var cfg = ConfigManager.shared.load()
    cfg.targetLimit = val
    if ConfigManager.shared.save(cfg) {
        let hw = HardwareBackend()
        _ = hw.setChargeLimitPercentage(val, delta: cfg.driftEnabled ? cfg.driftMargin : 1)
        print("✅ Saved target charge limit: \(val)%")
    } else {
        print("⚠️ Warning: Could not write configuration. Try running with 'sudo'.")
    }
}

func handleDrift(args: [String]) {
    guard let first = args.first?.lowercased() else {
        print("❌ Usage: chargeplan drift <on|off> [margin_percent]")
        exit(1)
    }
    
    let enabled = (first == "on" || first == "true" || first == "1")
    var margin = 3
    if args.count > 1, let m = Int(args[1]), (1...10).contains(m) {
        margin = m
    }
    
    let driftCommand = "DRIFT \(enabled ? "on" : "off") \(margin)"
    let driftWords = args.joined(separator: " ")
    if daemonAccepted(
        driftCommand,
        denied: "❌ Permission denied by daemon. Please run with sudo: sudo chargeplan drift \(driftWords)",
        offline: "❌ Power control requires root privileges (or start background daemon with 'sudo chargeplan install'):\n   sudo chargeplan drift \(driftWords)"
    ) {
        print("✅ Drift margin updated via socket: \(enabled ? "ENABLED (-\(margin)%)" : "DISABLED")")
        return
    }
    
    var cfg = ConfigManager.shared.load()
    cfg.driftEnabled = enabled
    cfg.driftMargin = margin
    if ConfigManager.shared.save(cfg) {
        let hw = HardwareBackend()
        _ = hw.setChargeLimitPercentage(cfg.targetLimit, delta: enabled ? margin : 1)
        print("✅ Drift margin updated: \(enabled ? "ENABLED (-\(margin)%)" : "DISABLED")")
    } else {
        print("⚠️ Warning: Could not write configuration. Try running with 'sudo'.")
    }
}

func handleDaemon() {
    print("🚀 Starting ChargePlan Controller Daemon...")
    
    if getuid() == 0 && FileManager.default.fileExists(atPath: ChargePlanLayout.legacyDaemonPlists[0]) {
        let legacyPlist = ChargePlanLayout.legacyDaemonPlists[0]
        let newPlist = ChargePlanLayout.daemonPlist
        if !FileManager.default.fileExists(atPath: newPlist) {
            if let content = try? String(contentsOfFile: legacyPlist, encoding: .utf8) {
                let updated = content.replacingOccurrences(of: ChargePlanLayout.previousDaemonLabel, with: ChargePlanLayout.daemonLabel)
                try? updated.write(toFile: newPlist, atomically: true, encoding: .utf8)
                _ = Shell.run("/bin/chmod", ["644", newPlist])
            }
        }
        try? FileManager.default.removeItem(atPath: legacyPlist)
    }
    
    let cfg = ConfigManager.shared.load()
    let governor = AIGovernor(config: cfg)
    governor.start()
    
    let server = UnixSocketServer(governor: governor)
    server.start()
    ipcServer = server
    print("🔌 ChargePlan Unix Socket listening at \(UnixSocketServer.defaultSocketPath)")
    
    // Register signal handler for clean shutdown
    signal(SIGINT) { _ in
        print("\n🛑 ChargePlan daemon terminating...")
        ipcServer?.stop()
        exit(0)
    }
    signal(SIGTERM) { _ in
        print("\n🛑 ChargePlan daemon terminating...")
        ipcServer?.stop()
        exit(0)
    }
    
    RunLoop.main.run()
}

func handleInstall() {
    guard getuid() == 0 else {
        print("❌ Installation requires root privileges. Please run:\n   sudo chargeplan install")
        exit(1)
    }
    
    let selfPath = CommandLine.arguments[0]
    let binSource: String
    if FileManager.default.isExecutableFile(atPath: selfPath) && !selfPath.contains("ChargePlanDaemon") {
        binSource = selfPath
    } else if FileManager.default.fileExists(atPath: ChargePlanLayout.cliBinary) {
        binSource = ChargePlanLayout.cliBinary
    } else {
        binSource = selfPath
    }
    
    let daemonBin = ChargePlanLayout.daemonBinary
    try? FileManager.default.createDirectory(atPath: ChargePlanLayout.supportDirectory, withIntermediateDirectories: true)
    
    guard SignedBinary.install(from: binSource, to: daemonBin) else {
        print("❌ Failed to install \(daemonBin)")
        exit(1)
    }
    SignedBinary.stripQuarantineAndSign(daemonBin)
    
    if !FileManager.default.fileExists(atPath: ChargePlanLayout.cliBinary) {
        try? FileManager.default.createDirectory(atPath: ChargePlanLayout.cliDirectory, withIntermediateDirectories: true)
        guard SignedBinary.install(from: daemonBin, to: ChargePlanLayout.cliBinary) else {
            print("❌ Failed to install \(ChargePlanLayout.cliBinary)")
            exit(1)
        }
        SignedBinary.stripQuarantineAndSign(ChargePlanLayout.cliBinary)
    }
    
    let plistPath = ChargePlanLayout.daemonPlist
    let plistContent = ChargePlanLayout.daemonPlistXML(program: daemonBin)
    
    for label in ChargePlanLayout.daemonLabels {
        _ = Shell.run("/bin/launchctl", ["bootout", "system/\(label)"])
    }
    for path in ChargePlanLayout.legacyDaemonPlists {
        try? FileManager.default.removeItem(atPath: path)
    }
    
    do {
        try plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)
        _ = Shell.run("/bin/chmod", ["644", plistPath])
        
        Thread.sleep(forTimeInterval: 0.3)
        _ = Shell.run("/bin/launchctl", ["bootstrap", "system", plistPath])
        _ = Shell.run("/bin/launchctl", ["kickstart", "-k", "system/\(ChargePlanLayout.daemonLabel)"])
        
        print("✅ ChargePlan LaunchDaemon installed and bootstrapped successfully!")
        print("   Daemon name: ChargePlanDaemon (\(daemonBin))")
        print("   CLI command: chargeplan (\(ChargePlanLayout.cliBinary))")
        print("   Plist: \(plistPath)")
        print("   Logs:  \(ChargePlanLayout.stdoutLog)")
    } catch {
        print("❌ Failed to install LaunchDaemon: \(error.localizedDescription)")
        exit(1)
    }
}

func handleUninstall() {
    guard getuid() == 0 else {
        print("❌ Uninstallation requires root privileges. Please run:\n   sudo chargeplan uninstall")
        exit(1)
    }
    
    // Restore normal charging before removing daemon
    let hw = HardwareBackend()
    _ = hw.setChargingInhibited(false)
    _ = hw.setChargeLimitPercentage(100)
    
    for label in ChargePlanLayout.daemonLabels {
        _ = Shell.run("/bin/launchctl", ["bootout", "system/\(label)"])
    }
    
    try? FileManager.default.removeItem(atPath: ChargePlanLayout.daemonPlist)
    for path in ChargePlanLayout.legacyDaemonPlists {
        try? FileManager.default.removeItem(atPath: path)
    }
    try? FileManager.default.removeItem(atPath: ChargePlanLayout.supportDirectory)
    try? FileManager.default.removeItem(atPath: ChargePlanLayout.legacySupportDirectory)
    try? FileManager.default.removeItem(atPath: ChargePlanLayout.socketPath)
    try? FileManager.default.removeItem(atPath: ChargePlanLayout.legacySocketPath)
    print("✅ ChargePlan LaunchDaemon uninstalled successfully.")
}

func handleUpdate(args: [String]) {
    let checkOnly = args.contains("--check")
    let force = args.contains("--force")
    
    print("🔍 Checking GitHub for updates (current version: v\(VERSION))...")
    
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        defer { semaphore.signal() }
        guard let info = await UpdateChecker.checkForUpdate(currentVersion: VERSION, force: true) else {
            print("⚠️ Could not fetch update information from GitHub (offline or rate-limited).")
            return
        }
        
        if !info.isNewer && !force {
            print("✅ ChargePlan is already up to date! (v\(VERSION))")
            return
        }
        
        print("""
        ========================================================================
        ⬆️  New version available: \(info.tagName) (Current: v\(VERSION))
        ========================================================================
        \(info.releaseNotes.isEmpty ? "No release notes provided." : info.releaseNotes)
        ========================================================================
        """)
        
        if checkOnly {
            print("Run 'sudo chargeplan update' to install.")
            return
        }
        
        if getuid() != 0 {
            // Check if user has write access to /Applications/ChargePlan.app and daemon socket is active
            let appPath = ChargePlanLayout.appBundle
            let appWritable = FileManager.default.isWritableFile(atPath: appPath) || FileManager.default.isWritableFile(atPath: "/Applications")
            let socketActive = FileManager.default.fileExists(atPath: ChargePlanLayout.socketPath)
            if appWritable && socketActive && !info.dmgUrl.isEmpty {
                print("⚡ Updating ChargePlan.app and background daemon via root IPC (no sudo required)…")
                do {
                    guard let dmgUrl = URL(string: info.dmgUrl) else {
                        print("❌ Invalid DMG URL: \(info.dmgUrl)")
                        exit(1)
                    }
                    try await UpdateChecker.installAppUpdate(dmgUrl: dmgUrl, relaunch: false) { step in
                        print("   → \(step)")
                    }
                    print("✅ ChargePlan successfully updated to \(info.tagName)!")
                    return
                } catch {
                    print("⚠️ Non-root update could not complete (\(error.localizedDescription)). Retrying with sudo requirement.")
                }
            }
            
            print("❌ Root privileges required to install update. Please run:\n   sudo chargeplan update")
            exit(1)
        }
        
        do {
            guard let binUrl = URL(string: info.binaryUrl) else {
                print("❌ Invalid binary download URL: \(info.binaryUrl)")
                exit(1)
            }
            try await UpdateChecker.installCLIUpdate(binaryUrl: binUrl) { step in
                print("   → \(step)")
            }
            
            // If /Applications/ChargePlan.app exists, update it too
            if FileManager.default.fileExists(atPath: ChargePlanLayout.appBundle),
               let dmgUrl = URL(string: info.dmgUrl) {
                print("🖥  Updating \(ChargePlanLayout.appBundle)...")
                try await UpdateChecker.installAppUpdate(dmgUrl: dmgUrl, relaunch: false) { step in
                    print("   → \(step)")
                }
            }
            
            print("✅ ChargePlan successfully updated to \(info.tagName)!")
        } catch {
            print("❌ Update failed: \(error.localizedDescription)")
            exit(1)
        }
    }
    semaphore.wait()
}

/// The daemon accepted the command. A permission denial exits. A missing
/// daemon returns false so the caller can write the config as root.
func daemonAccepted(_ command: String, denied: String, offline: String) -> Bool {
    if let resp = UnixSocketClient.send(command) {
        if UnixSocketClient.isSuccess(resp) {
            return true
        }
        if resp.contains("Permission denied") {
            print(denied)
            exit(1)
        }
    }
    guard getuid() == 0 else {
        print(offline)
        exit(1)
    }
    return false
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first?.lowercased() else {
    handleStatus(jsonOutput: false)
    exit(0)
}

switch command {
case "status":
    let isJson = args.contains("--json")
    handleStatus(jsonOutput: isJson)
case "set":
    handleSet(args: Array(args.dropFirst()))
case "drift", "deadband":
    handleDrift(args: Array(args.dropFirst()))
case "daemon":
    handleDaemon()
case "install":
    handleInstall()
case "uninstall":
    handleUninstall()
case "update":
    handleUpdate(args: Array(args.dropFirst()))
case "version", "--version", "-v":
    print("ChargePlan version \(VERSION)")
case "help", "--help", "-h":
    printHelp()
default:
    print("Unknown command: '\(command)'")
    printHelp()
    exit(1)
}
