import Foundation
import notify

/// Imperative shell driving `GovernorPolicy` via event-driven Darwin power notifications
/// and a bounded `DispatchSourceTimer` with deterministic per-tick autorelease pool draining.
public final class AIGovernor {
    public let monitor: BatteryMonitor
    public let hardware: HardwareBackend

    public var config: GovernorConfig {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _config
    }

    public var state: GovernorState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _state
    }

    private var _config: GovernorConfig
    private var _state: GovernorState
    private var memory: CeilingMemory
    private var isRunning = false
    private var timer: DispatchSourceTimer?
    private var scheduledPollInterval: Double = 5.0
    private var powerSourceNotifyToken: Int32 = NOTIFY_TOKEN_INVALID
    private var powerPercentNotifyToken: Int32 = NOTIFY_TOKEN_INVALID
    private var lastEventEvalAt: Date = .distantPast
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private let queue = DispatchQueue(
        label: "io.github.wixe.chargeplan.governor",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private let stateLock = NSLock()

    public init(config: GovernorConfig = ConfigManager.shared.load()) {
        queue.setSpecific(key: Self.queueKey, value: 1)
        let monitor = BatteryMonitor()
        let hardware = HardwareBackend()
        let status = monitor.getCurrentStatus(maxAge: 0)
        let opening = GovernorPolicy.openingCeiling(target: config.targetLimit, percent: status.percent)

        var initialState = GovernorState.initial
        initialState.activeTarget = opening.ceiling

        var initialMemory = CeilingMemory(lowWater: opening.lowWater)
        if status.isACConnected {
            let now = Date()
            _ = hardware.setChargeLimitPercentage(
                opening.ceiling,
                delta: config.driftEnabled ? config.driftMargin : 1,
                force: true
            )
            initialMemory = CeilingMemory(
                lowWater: opening.lowWater,
                chargeCatch: nil,
                lastRequestedCeiling: opening.ceiling,
                lastReassertAt: now
            )
        }

        self.monitor = monitor
        self.hardware = hardware
        self._config = config
        self._state = initialState
        self.memory = initialMemory
        self.scheduledPollInterval = max(1.0, config.pollIntervalSeconds)
    }

    deinit {
        cancelAsyncSources()
    }

    private func runOnQueueSync<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return work()
        }
        return queue.sync(execute: work)
    }

    public func updateConfig(_ newConfig: GovernorConfig) {
        runOnQueueSync {
            autoreleasepool {
                let status = monitor.getCurrentStatus(maxAge: 0)
                let opening = GovernorPolicy.openingCeiling(target: newConfig.targetLimit, percent: status.percent)
                let now = Date()

                _ = ConfigManager.shared.save(newConfig)
                if status.isACConnected {
                    _ = hardware.setChargeLimitPercentage(
                        opening.ceiling,
                        delta: newConfig.driftEnabled ? newConfig.driftMargin : 1,
                        force: true
                    )
                }

                stateLock.lock()
                self._config = newConfig
                self._state.activeTarget = opening.ceiling
                self.memory = CeilingMemory(
                    lowWater: opening.lowWater,
                    chargeCatch: nil,
                    lastRequestedCeiling: status.isACConnected ? opening.ceiling : self.memory.lastRequestedCeiling,
                    lastReassertAt: status.isACConnected ? now : .distantPast
                )
                stateLock.unlock()

                rescheduleTimerIfNeeded(interval: newConfig.pollIntervalSeconds)
                evaluateTickLockedQueue()
            }
        }
    }

    public func start() {
        runOnQueueSync {
            stateLock.lock()
            guard !isRunning else {
                stateLock.unlock()
                return
            }
            isRunning = true
            let interval = max(1.0, _config.pollIntervalSeconds)
            scheduledPollInterval = interval
            stateLock.unlock()

            autoreleasepool {
                evaluateTickLockedQueue()
            }

            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(250))
            t.setEventHandler { [weak self] in
                autoreleasepool {
                    self?.evaluateTickLockedQueue()
                }
            }
            t.resume()
            self.timer = t

            registerPowerNotifications()
        }
    }

    public func stop() {
        runOnQueueSync {
            stateLock.lock()
            isRunning = false
            stateLock.unlock()
            cancelAsyncSources()
            _ = hardware.setChargingInhibited(false)
        }
    }

    private func registerPowerNotifications() {
        let handler: notify_handler_t = { [weak self] _ in
            autoreleasepool {
                guard let self else { return }
                let now = Date()
                guard now.timeIntervalSince(self.lastEventEvalAt) >= 0.35 else { return }
                self.lastEventEvalAt = now
                self.evaluateTickLockedQueue()
            }
        }
        var srcToken: Int32 = NOTIFY_TOKEN_INVALID
        if notify_register_dispatch("com.apple.system.powersources.source", &srcToken, queue, handler) == NOTIFY_STATUS_OK {
            self.powerSourceNotifyToken = srcToken
        }
        var pctToken: Int32 = NOTIFY_TOKEN_INVALID
        if notify_register_dispatch("com.apple.system.powersources.percent", &pctToken, queue, handler) == NOTIFY_STATUS_OK {
            self.powerPercentNotifyToken = pctToken
        }
    }

    private func cancelAsyncSources() {
        timer?.cancel()
        timer = nil
        if powerSourceNotifyToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(powerSourceNotifyToken)
            powerSourceNotifyToken = NOTIFY_TOKEN_INVALID
        }
        if powerPercentNotifyToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(powerPercentNotifyToken)
            powerPercentNotifyToken = NOTIFY_TOKEN_INVALID
        }
    }

    private func rescheduleTimerIfNeeded(interval: Double) {
        let clamped = max(1.0, interval)
        guard abs(clamped - scheduledPollInterval) >= 0.1, let timer else { return }
        scheduledPollInterval = clamped
        timer.schedule(deadline: .now() + clamped, repeating: clamped, leeway: .milliseconds(250))
    }

    public func evaluateTick() {
        runOnQueueSync {
            evaluateTickLockedQueue()
        }
    }

    private func evaluateTickLockedQueue() {
        autoreleasepool {
            let status = monitor.getCurrentStatus()
            let diskConfig = ConfigManager.shared.load()
            let usesNative = hardware.isNativePowerUI
            let powerd = (status.isACConnected && usesNative)
                ? hardware.powerdSnapshot()
                : PowerdSnapshot(enforcedSoc: nil, reportedNoCeiling: false)
            let now = Date()

            stateLock.lock()
            let currentConfig = self._config
            let currentState = self._state
            let currentMemory = self.memory
            stateLock.unlock()

            let transition = GovernorPolicy.evaluate(
                config: currentConfig,
                diskConfig: diskConfig,
                state: currentState,
                memory: currentMemory,
                battery: status,
                powerd: powerd,
                usesNativePowerUI: usesNative,
                now: now
            )

            var finalState = transition.state
            for effect in transition.effects {
                switch effect {
                case let .publishCeiling(limit, delta, force):
                    let ok = hardware.setChargeLimitPercentage(limit, delta: delta, force: force)
                    if !ok {
                        finalState.isChargingInhibited = false
                        finalState.consecutiveErrors += 1
                        let enforcedText = powerd.enforcedSoc.map { "\($0)%" } ?? "none"
                        finalState.lastActionReason = "Failed to publish SoC ceiling at \(limit)% (powerd was \(enforcedText))"
                    }
                case let .setChargingInhibited(inhibit):
                    let ok = hardware.setChargingInhibited(inhibit)
                    if !ok {
                        finalState.consecutiveErrors += 1
                    }
                }
            }

            stateLock.lock()
            self._config = transition.config
            self._state = finalState
            self.memory = transition.memory
            stateLock.unlock()

            rescheduleTimerIfNeeded(interval: transition.config.pollIntervalSeconds)
        }
    }

    public func getCombinedReport() -> [String: Any] {
        autoreleasepool {
            let batt = monitor.getCurrentStatus()
            let enforced = hardware.powerdSocLimit() ?? -1
            let backend = hardware.modeName

            stateLock.lock()
            let cfg = self._config
            let st = self._state
            stateLock.unlock()

            return ChargeReport.dictionary(
                battery: batt,
                config: cfg,
                state: st,
                backend: backend,
                enforcedSoc: enforced
            )
        }
    }
}
