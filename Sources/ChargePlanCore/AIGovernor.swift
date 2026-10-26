import Foundation

public class AIGovernor {
    public let monitor: BatteryMonitor
    public let hardware: HardwareBackend
    public private(set) var config: GovernorConfig
    public private(set) var state: GovernorState
    
    /// How often to republish a ceiling that powerd is not currently advertising.
    /// The hardware backend also refuses to rewrite the same value within 15s.
    private static let ceilingReassertInterval: TimeInterval = 60
    private var isRunning = false
    private let queue = DispatchQueue(label: "io.github.wixe.chargeplan.governor", qos: .utility)
    private let stateLock = NSLock()
    private var lastReassertAt = Date.distantPast
    
    public init(config: GovernorConfig = ConfigManager.shared.load()) {
        self.monitor = BatteryMonitor()
        self.hardware = HardwareBackend()
        self.config = config
        self.state = GovernorState.initial
        self.state.activeTarget = config.targetLimit
        _ = self.hardware.setChargeLimitPercentage(config.targetLimit, delta: config.driftEnabled ? config.driftMargin : 1, force: true)
        self.lastReassertAt = Date()
    }
    
    public func updateConfig(_ newConfig: GovernorConfig) {
        stateLock.lock()
        self.config = newConfig
        self.state.activeTarget = newConfig.targetLimit
        stateLock.unlock()
        _ = ConfigManager.shared.save(newConfig)
        _ = hardware.setChargeLimitPercentage(newConfig.targetLimit, delta: newConfig.driftEnabled ? newConfig.driftMargin : 1, force: true)
        stateLock.lock()
        lastReassertAt = Date()
        stateLock.unlock()
        evaluateTick()
    }
    
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        
        queue.async { [weak self] in
            self?.evaluateTick()
            while self?.isRunning == true {
                let interval = self?.config.pollIntervalSeconds ?? 5.0
                Thread.sleep(forTimeInterval: interval)
                self?.evaluateTick()
            }
        }
    }
    
    public func stop() {
        isRunning = false
        // Restore normal charging on an explicit shutdown. The daemon's
        // SIGTERM handler does not call this, so a restart keeps the ceiling.
        _ = hardware.setChargingInhibited(false)
    }
    
    public func evaluateTick() {
        let status = monitor.getCurrentStatus()
        let diskConfig = ConfigManager.shared.load()
        stateLock.lock()
        defer { stateLock.unlock() }
        
        if diskConfig != self.config {
            self.config = diskConfig
            self.state.activeTarget = diskConfig.targetLimit
            _ = hardware.setChargeLimitPercentage(diskConfig.targetLimit, delta: diskConfig.driftEnabled ? diskConfig.driftMargin : 1, force: true)
            lastReassertAt = Date()
        }
        
        guard status.isACConnected else {
            state.modeDescription = "Running on Battery Power (\(status.percent)%)"
            return
        }
        
        if config.thermalProtectionEnabled && (status.thermalState.contains("Serious") || status.thermalState.contains("Critical")) {
            if !state.isThermalThrottled {
                _ = hardware.setChargingInhibited(true)
                state.isThermalThrottled = true
                state.isChargingInhibited = true
                state.lastActionTimestamp = Date()
                state.lastActionReason = "Thermal protection activated (Thermal State: \(status.thermalState))"
            }
            state.modeDescription = "Thermal Throttling Active (Cooling Down)"
            return
        } else if state.isThermalThrottled {
            state.isThermalThrottled = false
            state.lastActionReason = "Thermal state normalized"
        }
        
        let target = config.targetLimit
        let lowerBound = max(20, target - (config.driftEnabled ? config.driftMargin : 1))
        
        if hardware.modeName.contains("Native PowerUI") {
            publishNativeCeilingIfNeeded(target: target, status: status)
            describeNativeMode(target: target, lowerBound: lowerBound, status: status)
            return
        }
        
        // Legacy / direct-SMC path: classic hysteresis.
        if status.percent >= target {
            if status.isCharging || !state.isChargingInhibited {
                let success = hardware.setChargingInhibited(true)
                state.isChargingInhibited = true
                state.inDrift = true
                state.lastActionTimestamp = Date()
                state.lastActionReason = "Target reached (\(status.percent)% >= \(target)%). Inhibiting charge."
                state.modeDescription = "Holding Target at \(target)% (AC Pass-Through)"
                if !success { state.consecutiveErrors += 1 }
            } else {
                state.modeDescription = "Holding Target at \(target)% (Idle AC Pass-Through)"
            }
            return
        }
        
        if status.percent <= lowerBound {
            if state.isChargingInhibited || !status.isCharging {
                let success = hardware.setChargingInhibited(false)
                state.isChargingInhibited = false
                state.inDrift = false
                state.lastActionTimestamp = Date()
                state.lastActionReason = "Battery reached lower drift threshold (\(status.percent)% <= \(lowerBound)%). Re-enabling charge."
                state.modeDescription = "Gentle Charging to \(target)%"
                if !success { state.consecutiveErrors += 1 }
            } else {
                state.modeDescription = "Charging to \(target)% (\(status.percent)%)"
            }
            return
        }
        
        if config.driftEnabled && state.inDrift {
            state.modeDescription = "Drift Margin (\(status.percent)% within \(lowerBound)%-\(target)%)"
        } else {
            state.modeDescription = "Optimal Range (\(status.percent)%)"
        }
    }
    
    /// Republish when powerd is advertising a different ceiling, or when the
    /// pack is charging above the hold anyway. A matching ceiling is left
    /// alone, including while the pack discharges down to it. An unreadable
    /// pmset capture is not proof the ceiling is gone.
    private func publishNativeCeilingIfNeeded(target: Int, status: BatteryStatus) {
        let enforced = hardware.powerdSocLimit()
        let lowerBound = max(20, target - (config.driftEnabled ? config.driftMargin : 1))
        let chargingAboveHold = status.amperageMA > 50 && status.percent > lowerBound
        if enforced == target && !chargingAboveHold {
            state.isChargingInhibited = target < 100
            return
        }
        if enforced == nil && !hardware.powerdReportedNoCeiling() && !chargingAboveHold {
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastReassertAt) >= Self.ceilingReassertInterval else { return }
        lastReassertAt = now
        let delta = config.driftEnabled ? config.driftMargin : 1
        let success = hardware.setChargeLimitPercentage(target, delta: delta)
        state.isChargingInhibited = success && target < 100
        state.lastActionTimestamp = now
        let enforcedText = enforced.map { "\($0)%" } ?? "none"
        state.lastActionReason = success
            ? "Published SoC ceiling at \(target)% (powerd was \(enforcedText), battery \(status.percent)%)"
            : "Failed to publish SoC ceiling at \(target)% (powerd was \(enforcedText))"
        if !success { state.consecutiveErrors += 1 }
    }
    
    private func describeNativeMode(target: Int, lowerBound: Int, status: BatteryStatus) {
        let enforced = hardware.powerdSocLimit()
        let drawingCharge = status.isCharging || status.amperageMA > 50
        if status.percent >= target {
            state.inDrift = true
            if drawingCharge {
                let liveText = enforced.map { "\($0)%" } ?? "not armed"
                state.modeDescription = "Stopping charge at \(target)% (battery \(status.percent)%, \(status.amperageMA)mA, powerd \(liveText))"
            } else if status.amperageMA < -50 {
                state.modeDescription = "Above \(target)% target — discharging toward it (\(status.percent)%, \(status.amperageMA)mA)"
            } else if status.amperageMA == 0 {
                state.modeDescription = "Holding Target at \(target)% (Idle AC Pass-Through)"
            } else {
                state.modeDescription = "Holding Target at \(target)% (AC Pass-Through)"
            }
        } else if status.percent <= lowerBound && config.driftEnabled {
            state.inDrift = false
            state.modeDescription = "Charging to Target \(target)% — battery at \(status.percent)%"
        } else {
            let liveText = enforced.map { "powerd \($0)%" } ?? "powerd not armed"
            state.modeDescription = "SoC ceiling active at \(target)% (\(status.percent)%, \(liveText))"
        }
    }
    
    public func getCombinedReport() -> [String: Any] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return ChargeReport.dictionary(
            battery: monitor.getCurrentStatus(),
            config: config,
            state: state,
            backend: hardware.modeName,
            enforcedSoc: hardware.powerdSocLimit() ?? -1
        )
    }
}
