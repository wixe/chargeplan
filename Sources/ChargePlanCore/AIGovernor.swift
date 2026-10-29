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
    /// Ceiling published after the configured stop was missed while charging.
    /// It sits one point above the pack so the stop is reached from below.
    /// The saved setpoint is left unchanged. Cleared once the pack falls back
    /// to that setpoint.
    private var raisedHold: Int?
    
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
        self.raisedHold = nil
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
            self.raisedHold = nil
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
            publishNativeCeilingIfNeeded(target: target, lowerBound: lowerBound, status: status)
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
    
    /// One point above the pack, and never 100. A ceiling of 100 clears the limit.
    private func catchLevel(percent: Int) -> Int {
        min(99, percent + 1)
    }
    
    /// Publish `ceiling` when powerd is advertising something else, or when
    /// current is still flowing at or above that ceiling. A charge that is
    /// still climbing toward the ceiling is left alone.
    private func publishCeiling(_ ceiling: Int, status: BatteryStatus, immediate: Bool) {
        let enforced = hardware.powerdSocLimit()
        let chargingPastCeiling = status.amperageMA > 50 && status.percent >= ceiling
        if enforced == ceiling && !chargingPastCeiling {
            state.isChargingInhibited = ceiling < 100 && status.amperageMA <= 50
            return
        }
        if !immediate && enforced == nil && !hardware.powerdReportedNoCeiling() && !chargingPastCeiling {
            return
        }
        let now = Date()
        if !immediate && now.timeIntervalSince(lastReassertAt) < Self.ceilingReassertInterval {
            return
        }
        lastReassertAt = now
        let delta = config.driftEnabled ? config.driftMargin : 1
        let success = hardware.setChargeLimitPercentage(ceiling, delta: delta, force: immediate)
        state.isChargingInhibited = success && ceiling < 100 && !chargingPastCeiling
        state.lastActionTimestamp = now
        let enforcedText = enforced.map { "\($0)%" } ?? "none"
        state.lastActionReason = success
            ? "Published SoC ceiling at \(ceiling)% (powerd was \(enforcedText), battery \(status.percent)%)"
            : "Failed to publish SoC ceiling at \(ceiling)% (powerd was \(enforcedText))"
        if !success { state.consecutiveErrors += 1 }
    }
    
    /// A charge that has already passed the setpoint will not stop if the
    /// ceiling stays below the pack. Raise it to one point above the current
    /// level so the stop is reached from below, and keep that raised ceiling
    /// until the pack falls back to the saved setpoint.
    private func publishNativeCeilingIfNeeded(target: Int, lowerBound: Int, status: BatteryStatus) {
        let charging = status.isCharging || status.amperageMA > 50
        if status.percent <= target {
            raisedHold = nil
            state.activeTarget = target
            publishCeiling(target, status: status, immediate: false)
            return
        }
        if charging {
            let reached = catchLevel(percent: status.percent)
            if let current = raisedHold, reached > current {
                raisedHold = reached
            } else if raisedHold == nil {
                raisedHold = reached
            }
            let hold = raisedHold ?? reached
            state.activeTarget = hold
            publishCeiling(hold, status: status, immediate: hardware.powerdSocLimit() != hold)
            return
        }
        if var hold = raisedHold {
            let margin = config.driftEnabled ? config.driftMargin : 1
            if status.percent <= hold - margin {
                hold = min(hold, catchLevel(percent: status.percent))
                raisedHold = hold
            }
            state.activeTarget = hold
            publishCeiling(hold, status: status, immediate: hardware.powerdSocLimit() != hold)
            return
        }
        state.activeTarget = target
        let chargingAboveHold = status.amperageMA > 50 && status.percent > lowerBound
        if hardware.powerdSocLimit() == target && !chargingAboveHold {
            state.isChargingInhibited = target < 100
            return
        }
        publishCeiling(target, status: status, immediate: false)
    }
    
    private func describeNativeMode(target: Int, lowerBound: Int, status: BatteryStatus) {
        let enforced = hardware.powerdSocLimit()
        let drawingCharge = status.isCharging || status.amperageMA > 50
        if let hold = raisedHold, hold > target {
            state.inDrift = true
            state.activeTarget = hold
            if drawingCharge && status.percent < hold {
                state.modeDescription = "Missed \(target)%. Charging to \(hold)% from below (battery \(status.percent)%, \(status.amperageMA)mA)"
            } else if drawingCharge {
                state.modeDescription = "Missed \(target)%. Stopping at the \(hold)% catch (battery \(status.percent)%, \(status.amperageMA)mA)"
            } else {
                state.modeDescription = "Missed \(target)%. Holding the \(hold)% catch (battery \(status.percent)%)"
            }
            return
        }
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
