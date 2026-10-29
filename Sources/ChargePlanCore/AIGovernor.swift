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
    /// Last ceiling handed to powerd by this process. Used so a repeat of the
    /// same number does not rewrite the policy every poll.
    private var lastRequestedCeiling = -1
    /// Lowest percent the pack has already reached since it rose above the
    /// user's setpoint. The published ceiling steps down with this value and
    /// never steps back up to a temporary stop. It is not moved below a level
    /// the pack has not already been at, because a ceiling under the pack
    /// makes powerd drain the battery.
    private var lowWater: Int?
    /// One-point stop frozen for the charge in progress. Discarded when
    /// current stops so it does not become the level the pack charges back to.
    private var chargeCatch: Int?
    
    public init(config: GovernorConfig = ConfigManager.shared.load()) {
        self.monitor = BatteryMonitor()
        self.hardware = HardwareBackend()
        self.config = config
        self.state = GovernorState.initial
        let status = self.monitor.getCurrentStatus()
        let ceiling = self.openingCeiling(target: config.targetLimit, percent: status.percent)
        self.state.activeTarget = ceiling
        // Publishing while on battery makes powerd drop the saved policy.
        // The first plugged-in tick installs the ceiling.
        if status.isACConnected {
            _ = self.hardware.setChargeLimitPercentage(ceiling, delta: config.driftEnabled ? config.driftMargin : 1, force: true)
            self.lastRequestedCeiling = ceiling
            self.lastReassertAt = Date()
        }
    }

    /// Ceiling to publish at launch. A pack already above the setpoint keeps
    /// a ceiling on its current level. Publishing the setpoint underneath it
    /// makes powerd drain the pack down.
    private func openingCeiling(target: Int, percent: Int) -> Int {
        if percent > target {
            let ceiling = min(99, percent)
            lowWater = ceiling
            return ceiling
        }
        lowWater = nil
        return target
    }
    
    public func updateConfig(_ newConfig: GovernorConfig) {
        stateLock.lock()
        self.config = newConfig
        self.lowWater = nil
        self.chargeCatch = nil
        let ceiling = self.openingCeiling(target: newConfig.targetLimit, percent: monitor.getCurrentStatus().percent)
        self.state.activeTarget = ceiling
        stateLock.unlock()
        _ = ConfigManager.shared.save(newConfig)
        _ = hardware.setChargeLimitPercentage(ceiling, delta: newConfig.driftEnabled ? newConfig.driftMargin : 1, force: true)
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
            self.lowWater = nil
            self.chargeCatch = nil
            lastReassertAt = Date.distantPast
        }
        
        guard status.isACConnected else {
            // Remember how far the pack has fallen. Do not publish here:
            // a write while unplugged clears the policy powerd is holding.
            if hardware.modeName.contains("Native PowerUI") {
                noteLowWater(target: config.targetLimit, percent: status.percent)
                state.activeTarget = lowWater ?? config.targetLimit
            }
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
        if ceiling == lastRequestedCeiling && now.timeIntervalSince(lastReassertAt) < 15 {
            return
        }
        if !immediate && now.timeIntervalSince(lastReassertAt) < Self.ceilingReassertInterval {
            return
        }
        lastReassertAt = now
        lastRequestedCeiling = ceiling
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
    
    /// Above the user's setpoint, the ceiling follows the pack downward and
    /// never returns to a temporary high. A one-point catch exists only while
    /// charge current is flowing, then it is discarded. The ceiling is not
    /// placed under a level the pack has not already reached.
    private func publishNativeCeilingIfNeeded(target: Int, status: BatteryStatus) {
        let charging = status.isCharging || status.amperageMA > 50
        let enforced = hardware.powerdSocLimit()
        if status.percent <= target {
            lowWater = nil
            chargeCatch = nil
            state.activeTarget = target
            publishCeiling(target, status: status, immediate: enforced != target)
            return
        }

        noteLowWater(target: target, percent: status.percent)
        var water = lowWater ?? min(99, status.percent)

        if charging {
            if chargeCatch == nil {
                chargeCatch = min(99, status.percent + 1)
            }
            state.activeTarget = water
            let catchNow = chargeCatch ?? water
            publishCeiling(catchNow, status: status, immediate: enforced != catchNow)
            return
        }

        // Current has stopped. Drop the temporary stop. A landing one point
        // above the low-water mark stays on the pack so that single point is
        // not drained back off. A larger automatic charge does not raise the
        // mark: the ceiling stays on the lower step, toward the user's setpoint.
        let catchWas = chargeCatch
        chargeCatch = nil
        if let catchWas, status.percent > water && status.percent <= catchWas {
            water = min(99, status.percent)
            lowWater = water
        }
        state.activeTarget = water
        publishCeiling(water, status: status, immediate: enforced != water)
    }

    /// Lowest percent already reached above the user's setpoint.
    /// A higher reading does not lift it.
    private func noteLowWater(target: Int, percent: Int) {
        let live = min(99, percent)
        guard live > target else {
            lowWater = nil
            return
        }
        if let water = lowWater {
            if live < water {
                lowWater = max(target, live)
            }
        } else {
            lowWater = live
        }
    }
    
    private func describeNativeMode(target: Int, lowerBound: Int, status: BatteryStatus) {
        let enforced = hardware.powerdSocLimit()
        let drawingCharge = status.isCharging || status.amperageMA > 50
        if status.percent > target, let catchNow = chargeCatch {
            state.inDrift = true
            state.activeTarget = lowWater ?? catchNow
            state.modeDescription = "Missed \(target)%. Stopping at \(catchNow)% from below (battery \(status.percent)%, \(status.amperageMA)mA)"
            return
        }
        if status.percent > target, let water = lowWater {
            state.inDrift = true
            state.activeTarget = water
            if status.percent > water {
                state.modeDescription = "Limit \(water)% toward \(target)% (battery \(status.percent)%, \(status.amperageMA)mA)"
            } else if status.amperageMA == 0 {
                state.modeDescription = "Limit \(water)% stepping toward \(target)% (Idle AC)"
            } else {
                state.modeDescription = "Limit \(water)% stepping toward \(target)% (battery \(status.percent)%, \(status.amperageMA)mA)"
            }
            return
        }
        if status.percent >= target {
            state.inDrift = true
            if drawingCharge {
                let liveText = enforced.map { "\($0)%" } ?? "not armed"
                state.modeDescription = "Stopping charge at \(target)% (battery \(status.percent)%, \(status.amperageMA)mA, powerd \(liveText))"
            } else if status.amperageMA < -50 {
                state.modeDescription = "At \(target)% target — drawing \(status.amperageMA)mA"
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
