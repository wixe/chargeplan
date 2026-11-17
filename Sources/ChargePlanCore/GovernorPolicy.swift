import Foundation

/// Immutable memory for Native PowerUI ceiling tracking across ticks.
public struct CeilingMemory: Equatable, Sendable {
    public let lowWater: Int?
    public let chargeCatch: Int?
    public let lastRequestedCeiling: Int
    public let lastReassertAt: Date

    public init(
        lowWater: Int? = nil,
        chargeCatch: Int? = nil,
        lastRequestedCeiling: Int = -1,
        lastReassertAt: Date = .distantPast
    ) {
        self.lowWater = lowWater
        self.chargeCatch = chargeCatch
        self.lastRequestedCeiling = lastRequestedCeiling
        self.lastReassertAt = lastReassertAt
    }

    public static let initial = CeilingMemory()
}

/// Snapshot of powerd's currently active SoC ceiling state.
public struct PowerdSnapshot: Equatable, Sendable {
    public let enforcedSoc: Int?
    public let reportedNoCeiling: Bool

    public init(enforcedSoc: Int?, reportedNoCeiling: Bool) {
        self.enforcedSoc = enforcedSoc
        self.reportedNoCeiling = reportedNoCeiling
    }
}

/// Side-effect descriptor emitted by the pure governor policy.
public enum GovernorEffect: Equatable, Sendable {
    case publishCeiling(limit: Int, delta: Int, force: Bool)
    case setChargingInhibited(Bool)
}

/// Pure output of a single governor evaluation step.
public struct GovernorTransition: Equatable, Sendable {
    public let config: GovernorConfig
    public let state: GovernorState
    public let memory: CeilingMemory
    public let effects: [GovernorEffect]

    public init(
        config: GovernorConfig,
        state: GovernorState,
        memory: CeilingMemory,
        effects: [GovernorEffect]
    ) {
        self.config = config
        self.state = state
        self.memory = memory
        self.effects = effects
    }
}

/// Pure functional core for ChargePlan's battery charge regulation state machine.
public enum GovernorPolicy {
    public static let defaultReassertInterval: TimeInterval = 60.0
    public static let minRepeatInterval: TimeInterval = 15.0

    /// Ceiling to publish at launch or config update. A pack already above the
    /// setpoint keeps a ceiling at its current level so powerd does not force-drain it.
    public static func openingCeiling(target: Int, percent: Int) -> (ceiling: Int, lowWater: Int?) {
        let clampedTarget = max(30, min(100, target))
        if percent > clampedTarget {
            let ceiling = min(99, percent)
            return (ceiling, ceiling)
        }
        return (clampedTarget, nil)
    }

    /// Lowest percent already reached above the user's setpoint. A higher reading never lifts it.
    public static func updatedLowWater(current: Int?, target: Int, percent: Int) -> Int? {
        let live = min(99, percent)
        guard live > target else {
            return nil
        }
        if let water = current {
            return live < water ? max(target, live) : water
        }
        return live
    }

    /// Pure state transition from `(config, diskConfig, state, memory, battery, powerd, now)`
    /// to `(nextConfig, nextState, nextMemory, effects)` with zero I/O or mutation of external state.
    public static func evaluate(
        config: GovernorConfig,
        diskConfig: GovernorConfig,
        state: GovernorState,
        memory: CeilingMemory,
        battery status: BatteryStatus,
        powerd: PowerdSnapshot,
        usesNativePowerUI: Bool,
        now: Date,
        reassertInterval: TimeInterval = defaultReassertInterval
    ) -> GovernorTransition {
        let configReloaded = (diskConfig != config)
        let activeConfig = configReloaded ? diskConfig : config
        var nextState = state
        var nextMemory = configReloaded
            ? CeilingMemory(
                lowWater: nil,
                chargeCatch: nil,
                lastRequestedCeiling: memory.lastRequestedCeiling,
                lastReassertAt: .distantPast
            )
            : memory

        if configReloaded {
            nextState.activeTarget = activeConfig.targetLimit
        }

        let target = activeConfig.targetLimit
        let lowerBound = max(20, target - (activeConfig.driftEnabled ? activeConfig.driftMargin : 1))

        // 1. Unplugged: track downward drift without writing to powerd (which would drop saved policy).
        guard status.isACConnected else {
            if usesNativePowerUI {
                let lw = updatedLowWater(current: nextMemory.lowWater, target: target, percent: status.percent)
                nextMemory = CeilingMemory(
                    lowWater: lw,
                    chargeCatch: nil,
                    lastRequestedCeiling: nextMemory.lastRequestedCeiling,
                    lastReassertAt: nextMemory.lastReassertAt
                )
                nextState.activeTarget = lw ?? target
                nextState.isChargingInhibited = false
            }
            nextState.isThermalThrottled = false
            if status.percent <= lowerBound {
                nextState.inDrift = false
            }
            nextState.modeDescription = "Running on Battery Power (\(status.percent)%)"
            return GovernorTransition(config: activeConfig, state: nextState, memory: nextMemory, effects: [])
        }

        // 2. Thermal protection guard.
        var recoveryEffects: [GovernorEffect] = []
        let isHot = status.thermalState.contains("Serious") || status.thermalState.contains("Critical")
        if activeConfig.thermalProtectionEnabled && isHot {
            var effects: [GovernorEffect] = []
            if !nextState.isThermalThrottled {
                effects.append(.setChargingInhibited(true))
                nextState.isThermalThrottled = true
                nextState.isChargingInhibited = true
                nextState.lastActionTimestamp = now
                nextState.lastActionReason = "Thermal protection activated (Thermal State: \(status.thermalState))"
            }
            nextState.modeDescription = "Thermal Throttling Active (Cooling Down)"
            return GovernorTransition(config: activeConfig, state: nextState, memory: nextMemory, effects: effects)
        } else if nextState.isThermalThrottled {
            nextState.isThermalThrottled = false
            nextState.lastActionTimestamp = now
            nextState.lastActionReason = "Thermal state normalized"
            if !usesNativePowerUI && !nextState.inDrift && status.percent > lowerBound && status.percent < target && nextState.isChargingInhibited {
                nextState.isChargingInhibited = false
                recoveryEffects.append(.setChargingInhibited(false))
            }
        }

        // 3. macOS Native PowerUI closed-loop ceiling control.
        if usesNativePowerUI {
            return evaluateNativePowerUI(
                config: activeConfig,
                state: nextState,
                memory: nextMemory,
                target: target,
                lowerBound: lowerBound,
                status: status,
                powerd: powerd,
                forcePublish: configReloaded,
                now: now,
                reassertInterval: reassertInterval
            )
        }

        // 4. Direct AppleSMC / Auxiliary CLI classic hysteresis.
        if status.percent >= target {
            if status.isCharging || !nextState.isChargingInhibited {
                nextState.isChargingInhibited = true
                nextState.inDrift = true
                nextState.lastActionTimestamp = now
                nextState.lastActionReason = "Target reached (\(status.percent)% >= \(target)%). Inhibiting charge."
                nextState.modeDescription = "Holding Target at \(target)% (AC Pass-Through)"
                return GovernorTransition(
                    config: activeConfig,
                    state: nextState,
                    memory: nextMemory,
                    effects: [.setChargingInhibited(true)]
                )
            } else {
                nextState.modeDescription = "Holding Target at \(target)% (Idle AC Pass-Through)"
                return GovernorTransition(config: activeConfig, state: nextState, memory: nextMemory, effects: [])
            }
        }

        if status.percent <= lowerBound {
            if nextState.isChargingInhibited || !status.isCharging {
                nextState.isChargingInhibited = false
                nextState.inDrift = false
                nextState.lastActionTimestamp = now
                nextState.lastActionReason = "Battery reached lower drift threshold (\(status.percent)% <= \(lowerBound)%). Re-enabling charge."
                nextState.modeDescription = "Gentle Charging to \(target)%"
                return GovernorTransition(
                    config: activeConfig,
                    state: nextState,
                    memory: nextMemory,
                    effects: [.setChargingInhibited(false)]
                )
            } else {
                nextState.modeDescription = "Charging to \(target)% (\(status.percent)%)"
                return GovernorTransition(config: activeConfig, state: nextState, memory: nextMemory, effects: [])
            }
        }

        if activeConfig.driftEnabled && nextState.inDrift {
            nextState.modeDescription = "Drift Margin (\(status.percent)% within \(lowerBound)%-\(target)%)"
        } else {
            nextState.modeDescription = "Optimal Range (\(status.percent)%)"
        }
        return GovernorTransition(config: activeConfig, state: nextState, memory: nextMemory, effects: recoveryEffects)
    }

    private static func evaluateNativePowerUI(
        config: GovernorConfig,
        state: GovernorState,
        memory: CeilingMemory,
        target: Int,
        lowerBound: Int,
        status: BatteryStatus,
        powerd: PowerdSnapshot,
        forcePublish: Bool,
        now: Date,
        reassertInterval: TimeInterval
    ) -> GovernorTransition {
        var nextState = state
        let charging = status.isCharging || status.amperageMA > 50
        let enforced = powerd.enforcedSoc

        let desiredCeiling: Int
        let nextLowWater: Int?
        let nextChargeCatch: Int?

        if status.percent <= target {
            nextLowWater = nil
            nextChargeCatch = nil
            nextState.activeTarget = target
            desiredCeiling = target
        } else {
            let computedWater = updatedLowWater(current: memory.lowWater, target: target, percent: status.percent)
            var water = computedWater ?? min(99, status.percent)

            if charging {
                let catchVal = memory.chargeCatch ?? min(99, status.percent + 1)
                nextLowWater = computedWater
                nextChargeCatch = catchVal
                nextState.activeTarget = water
                desiredCeiling = catchVal
            } else {
                if let catchWas = memory.chargeCatch, status.percent > water && status.percent <= catchWas {
                    water = min(99, status.percent)
                }
                nextLowWater = water
                nextChargeCatch = nil
                nextState.activeTarget = water
                desiredCeiling = water
            }
        }

        let immediate = forcePublish || (enforced != nil && enforced != desiredCeiling)
        let chargingPastCeiling = status.amperageMA > 50 && status.percent >= desiredCeiling

        var effects: [GovernorEffect] = []
        var lastRequested = memory.lastRequestedCeiling
        var lastReassert = memory.lastReassertAt

        if enforced == desiredCeiling && !chargingPastCeiling && !forcePublish {
            nextState.isChargingInhibited = desiredCeiling < 100 && status.amperageMA <= 50
        } else if !immediate && enforced == nil && !powerd.reportedNoCeiling && !chargingPastCeiling {
            // Transient empty pmset capture — leave existing ceiling untouched.
        } else if !forcePublish && desiredCeiling == lastRequested && now.timeIntervalSince(lastReassert) < minRepeatInterval {
            // Debounce identical ceiling within 15s.
        } else if !immediate && now.timeIntervalSince(lastReassert) < reassertInterval {
            // Wait for standard 60s reassertion window.
        } else {
            lastReassert = now
            lastRequested = desiredCeiling
            let delta = config.driftEnabled ? config.driftMargin : 1
            effects.append(.publishCeiling(limit: desiredCeiling, delta: delta, force: forcePublish))
            nextState.isChargingInhibited = desiredCeiling < 100 && !chargingPastCeiling
            nextState.lastActionTimestamp = now
            let enforcedText = enforced.map { "\($0)%" } ?? "none"
            nextState.lastActionReason = "Published SoC ceiling at \(desiredCeiling)% (powerd was \(enforcedText), battery \(status.percent)%)"
        }

        let updatedMemory = CeilingMemory(
            lowWater: nextLowWater,
            chargeCatch: nextChargeCatch,
            lastRequestedCeiling: lastRequested,
            lastReassertAt: lastReassert
        )

        nextState = describeNativeMode(
            config: config,
            state: nextState,
            memory: updatedMemory,
            target: target,
            lowerBound: lowerBound,
            status: status,
            enforced: enforced
        )

        return GovernorTransition(config: config, state: nextState, memory: updatedMemory, effects: effects)
    }

    public static func describeNativeMode(
        config: GovernorConfig,
        state: GovernorState,
        memory: CeilingMemory,
        target: Int,
        lowerBound: Int,
        status: BatteryStatus,
        enforced: Int?
    ) -> GovernorState {
        var nextState = state
        let drawingCharge = status.isCharging || status.amperageMA > 50

        if status.percent > target, let catchNow = memory.chargeCatch {
            nextState.inDrift = true
            nextState.activeTarget = memory.lowWater ?? catchNow
            nextState.modeDescription = "Missed \(target)%. Stopping at \(catchNow)% from below (battery \(status.percent)%, \(status.amperageMA)mA)"
            return nextState
        }

        if status.percent > target, let water = memory.lowWater {
            nextState.inDrift = true
            nextState.activeTarget = water
            if status.percent > water {
                nextState.modeDescription = "Limit \(water)% toward \(target)% (battery \(status.percent)%, \(status.amperageMA)mA)"
            } else if status.amperageMA == 0 {
                nextState.modeDescription = "Limit \(water)% stepping toward \(target)% (Idle AC)"
            } else {
                nextState.modeDescription = "Limit \(water)% stepping toward \(target)% (battery \(status.percent)%, \(status.amperageMA)mA)"
            }
            return nextState
        }

        if status.percent >= target {
            nextState.inDrift = true
            if drawingCharge {
                let liveText = enforced.map { "\($0)%" } ?? "not armed"
                nextState.modeDescription = "Stopping charge at \(target)% (battery \(status.percent)%, \(status.amperageMA)mA, powerd \(liveText))"
            } else if status.amperageMA < -50 {
                nextState.modeDescription = "At \(target)% target — drawing \(status.amperageMA)mA"
            } else if status.amperageMA == 0 {
                nextState.modeDescription = "Holding Target at \(target)% (Idle AC Pass-Through)"
            } else {
                nextState.modeDescription = "Holding Target at \(target)% (AC Pass-Through)"
            }
        } else if status.percent <= lowerBound && config.driftEnabled {
            nextState.inDrift = false
            nextState.modeDescription = "Charging to Target \(target)% — battery at \(status.percent)%"
        } else {
            let liveText = enforced.map { "powerd \($0)%" } ?? "powerd not armed"
            nextState.modeDescription = "SoC ceiling active at \(target)% (\(status.percent)%, \(liveText))"
        }
        return nextState
    }
}
