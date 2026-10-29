import XCTest
@testable import ChargePlanCore

final class ChargePlanTests: XCTestCase {
    func testBatteryMonitor() {
        let monitor = BatteryMonitor()
        let status = monitor.getCurrentStatus()
        XCTAssertGreaterThanOrEqual(status.percent, 0)
        XCTAssertLessThanOrEqual(status.percent, 100)
        XCTAssertGreaterThanOrEqual(status.exactPercent, 0.0)
        XCTAssertLessThanOrEqual(status.exactPercent, 100.0)
        XCTAssertFalse(status.serialNumber.isEmpty)
    }
    
    func testConfigManager() {
        let cfg = GovernorConfig.default
        XCTAssertEqual(cfg.targetLimit, 50)
        XCTAssertTrue(cfg.driftEnabled)
        XCTAssertEqual(cfg.driftMargin, 3)
        // Backwards compatibility alias
        XCTAssertTrue(cfg.deadbandEnabled)
        XCTAssertEqual(cfg.deadbandDelta, 3)
    }
    
    func testGovernorInitialization() {
        let governor = AIGovernor()
        let report = governor.getCombinedReport()
        XCTAssertNotNil(report["battery"])
        XCTAssertNotNil(report["governor"])
    }
    
    func testConfigSerialization() throws {
        let cfg = GovernorConfig(
            targetLimit: 80,
            driftEnabled: false,
            driftMargin: 5,
            thermalProtectionEnabled: true,
            autoServerMode: false,
            pollIntervalSeconds: 10.0
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(GovernorConfig.self, from: data)
        XCTAssertEqual(decoded.targetLimit, 80)
        XCTAssertFalse(decoded.driftEnabled)
        XCTAssertEqual(decoded.driftMargin, 5)
        // Backwards compatibility alias
        XCTAssertFalse(decoded.deadbandEnabled)
        XCTAssertEqual(decoded.deadbandDelta, 5)
    }
    
    func testLegacyDeadbandConfigDecoding() throws {
        let legacyJson = """
        {
            "targetLimit": 60,
            "deadbandEnabled": true,
            "deadbandDelta": 4,
            "thermalProtectionEnabled": true,
            "autoServerMode": true,
            "pollIntervalSeconds": 5.0
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(GovernorConfig.self, from: legacyJson)
        XCTAssertEqual(decoded.targetLimit, 60)
        XCTAssertTrue(decoded.driftEnabled)
        XCTAssertEqual(decoded.driftMargin, 4)
    }
    
    func testSMCParamStructLayout() {
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.size, 80)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.stride, 80)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.key), 0)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.vers), 4)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.pLimitData), 12)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.keyInfo), 28)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.result), 40)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.status), 41)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.data8), 42)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.data32), 44)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.bytes), 48)
    }
    
    func testUpdateSemverComparison() {
        XCTAssertEqual(UpdateChecker.compareVersion("0.2.0", "0.2.0"), .orderedSame)
        XCTAssertEqual(UpdateChecker.compareVersion("0.3.0", "0.2.0"), .orderedDescending)
        XCTAssertEqual(UpdateChecker.compareVersion("0.2.0", "0.3.0"), .orderedAscending)
        XCTAssertEqual(UpdateChecker.compareVersion("v1.0.0", "0.9.9"), .orderedDescending)
        XCTAssertEqual(UpdateChecker.compareVersion("0.2.1", "0.2.0"), .orderedDescending)
        XCTAssertEqual(UpdateChecker.compareVersion("0.2", "0.2.0"), .orderedSame)
        XCTAssertEqual(UpdateChecker.compareVersion("1.0.0", "v1.0.0"), .orderedSame)
        
        XCTAssertTrue(UpdateChecker.isVersion("0.3.0", newerThan: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isVersion("0.2.0", newerThan: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isVersion("0.1.9", newerThan: "0.2.0"))
    }
    
    func testReleaseInfoSerialization() throws {
        let info = ReleaseInfo(
            version: "0.4.3",
            tagName: "v0.4.3",
            title: "ChargePlan 0.4.3",
            releaseNotes: "Feature update",
            htmlUrl: "https://github.com/wixe/chargeplan/releases/tag/v0.4.3",
            dmgUrl: "https://github.com/wixe/chargeplan/raw/main/dist/ChargePlan.dmg",
            binaryUrl: "https://raw.githubusercontent.com/wixe/chargeplan/main/bin/chargeplan",
            isNewer: true
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(ReleaseInfo.self, from: data)
        XCTAssertEqual(decoded.version, "0.4.3")
        XCTAssertEqual(decoded.tagName, "v0.4.3")
        XCTAssertTrue(decoded.isNewer)
    }
    
    func testPowerdSocParsing() {
        let sample = """
        Battery level limits:
        (
                {
                chargeSocLimitSoc = 80;
                chargeSocLimitReason = manualChargeLimit;
            },
                {
                chargeSocLimitSoc = 50;
            }
        )
        """
        XCTAssertEqual(HardwareBackend.parsePowerdSocLimits(sample), [80, 50])
        XCTAssertEqual(HardwareBackend.parsePowerdSocLimits("No battery level limits set\n"), [])
        let crowded = "chargeSocLimitOwner = 71566; chargeSocLimitSoc = 50; chargeSocLimitDrain = 1;"
        XCTAssertEqual(HardwareBackend.parsePowerdSocLimits(crowded), [50])
        let live = """
        (
                {
                Terminated = 0;
                chargeSocLimitNoChargeToFull = 0;
                chargeSocLimitSoc = 50;
            },
                {
                Terminated = 0;
                chargeSocLimitNoChargeToFull = 1;
                chargeSocLimitSoc = 80;
            }
        )
        """
        let records = HardwareBackend.parsePowerdSocLimitRecords(live)
        XCTAssertEqual(records.map(\.soc), [50, 80])
        XCTAssertFalse(records[0].noChargeToFull)
        XCTAssertTrue(records[1].noChargeToFull)
        XCTAssertFalse(records[0].terminated)
    }
    
    func testReportOmitsKickFields() {
        let governor = AIGovernor()
        let report = governor.getCombinedReport()
        guard let gov = report["governor"] as? [String: Any] else {
            XCTFail("Missing governor dictionary")
            return
        }
        XCTAssertNotNil(gov["enforced_soc"])
        XCTAssertNil(gov["kick_count"])
        XCTAssertNil(gov["last_kick_percent"])
        XCTAssertNil(gov["kick_cooldown_seconds"])
    }
    
    func testLegacyKickConfigKeysAreIgnored() throws {
        let json = """
        {"targetLimit":50,"driftEnabled":true,"driftMargin":3,"thermalProtectionEnabled":true,"autoServerMode":true,"pollIntervalSeconds":5,"kickCooldownSeconds":12,"kickDwellSeconds":8}
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(GovernorConfig.self, from: json)
        XCTAssertEqual(cfg.targetLimit, 50)
        XCTAssertEqual(cfg.driftMargin, 3)
        let encoded = try JSONEncoder().encode(cfg)
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNil(obj?["kickCooldownSeconds"])
        XCTAssertNil(obj?["kickDwellSeconds"])
    }
    
    func testSailingConfigKeysStillDecode() throws {
        let json = """
        {"targetLimit":70,"sailingEnabled":false,"sailingDelta":2,"thermalProtectionEnabled":true,"autoServerMode":true,"pollIntervalSeconds":5}
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(GovernorConfig.self, from: json)
        XCTAssertEqual(cfg.targetLimit, 70)
        XCTAssertFalse(cfg.driftEnabled)
        XCTAssertEqual(cfg.driftMargin, 2)
    }
    
    func testDaemonPlistUsesCurrentLabel() {
        let xml = ChargePlanLayout.daemonPlistXML(program: ChargePlanLayout.daemonBinary)
        XCTAssertTrue(xml.contains("<string>\(ChargePlanLayout.daemonLabel)</string>"))
        XCTAssertTrue(xml.contains("<string>\(ChargePlanLayout.daemonBinary)</string>"))
        XCTAssertTrue(xml.contains("<key>KeepAlive</key>"))
        XCTAssertFalse(xml.contains("chargecap"))
    }
    
    func testAppLaunchAgentStaysInBackground() {
        let xml = ChargePlanLayout.appLaunchAgentXML(executable: "\(ChargePlanLayout.appBundle)/Contents/MacOS/ChargePlanApp")
        XCTAssertTrue(xml.contains(ChargePlanLayout.appLabel))
        XCTAssertTrue(xml.contains("--background"))
    }
    
    func testChargeReportShape() {
        let batt = BatteryStatus(
            percent: 60,
            exactPercent: 60.2,
            isCharging: false,
            isACConnected: true,
            isFullyCharged: false,
            cycleCount: 10,
            voltageMV: 11000,
            amperageMA: 0,
            wattageW: 0,
            designCapacityMAh: 4000,
            fullChargeCapacityMAh: 3800,
            remainingCapacityMAh: 2200,
            nominalCapacityMAh: 3900,
            healthPercent: 95,
            timeRemainingMinutes: 100,
            serialNumber: "TEST",
            thermalState: "Nominal"
        )
        let report = ChargeReport.dictionary(
            battery: batt,
            config: .default,
            state: .initial,
            backend: "test",
            enforcedSoc: 60
        )
        let gov = report["governor"] as? [String: Any]
        XCTAssertEqual(gov?["enforced_soc"] as? Int, 60)
        XCTAssertEqual(gov?["version"] as? String, ChargePlanVersion)
        XCTAssertEqual(gov?["deadband_enabled"] as? Bool, true)
        XCTAssertNil(gov?["kick_count"])
    }
    
    func testShellEcho() {
        let result = Shell.run("/bin/echo", ["chargeplan"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "chargeplan\n")
    }
    
    func testSignedBinaryRejectsTinySource() throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("cp-tiny-\(UUID().uuidString)")
        try Data("nope".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("cp-dest-\(UUID().uuidString)")
        XCTAssertFalse(SignedBinary.install(from: src.path, to: dest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(SignedBinary.byteCount(src.path), 4)
    }
}
