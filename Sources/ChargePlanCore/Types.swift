import Foundation

public struct BatteryStatus: Codable, Equatable, Sendable {
    public let percent: Int
    public let exactPercent: Double
    public let isCharging: Bool
    public let isACConnected: Bool
    public let isFullyCharged: Bool
    public let cycleCount: Int
    public let voltageMV: Int
    public let amperageMA: Int
    public let wattageW: Double
    public let designCapacityMAh: Int
    public let fullChargeCapacityMAh: Int
    public let remainingCapacityMAh: Int
    public let nominalCapacityMAh: Int
    public let healthPercent: Double
    public let timeRemainingMinutes: Int
    public let serialNumber: String
    public let thermalState: String
    public let temperatureC: Double?
    public let cellVoltagesMV: [Int]
    public let notChargingReason: Int
    public let timestamp: Date
    
    public var cellImbalanceMV: Int? {
        guard let minV = cellVoltagesMV.min(), let maxV = cellVoltagesMV.max(), cellVoltagesMV.count >= 2 else { return nil }
        return maxV - minV
    }
    
    /// Energy in the pack now, and the energy a full charge holds, both in watt-hours.
    /// Estimated from charge (mAh) times the live pack voltage.
    public var energyWattHours: (remaining: Double, total: Double)? {
        guard voltageMV > 0, remainingCapacityMAh > 0, fullChargeCapacityMAh > 0 else { return nil }
        let volts = Double(voltageMV) / 1000.0
        let remaining = Double(remainingCapacityMAh) / 1000.0 * volts
        let total = Double(fullChargeCapacityMAh) / 1000.0 * volts
        return (remaining, total)
    }
    
    enum CodingKeys: String, CodingKey {
        case percent
        case exactPercent
        case isCharging
        case isACConnected
        case isFullyCharged
        case cycleCount
        case voltageMV
        case amperageMA
        case wattageW
        case designCapacityMAh
        case fullChargeCapacityMAh
        case remainingCapacityMAh
        case nominalCapacityMAh
        case healthPercent
        case timeRemainingMinutes
        case serialNumber
        case thermalState
        case temperatureC
        case cellVoltagesMV
        case notChargingReason
        case timestamp
    }
    
    public init(
        percent: Int,
        exactPercent: Double? = nil,
        isCharging: Bool,
        isACConnected: Bool,
        isFullyCharged: Bool,
        cycleCount: Int,
        voltageMV: Int,
        amperageMA: Int,
        wattageW: Double,
        designCapacityMAh: Int,
        fullChargeCapacityMAh: Int,
        remainingCapacityMAh: Int = 0,
        nominalCapacityMAh: Int,
        healthPercent: Double,
        timeRemainingMinutes: Int,
        serialNumber: String,
        thermalState: String,
        temperatureC: Double? = nil,
        cellVoltagesMV: [Int] = [],
        notChargingReason: Int = 0,
        timestamp: Date = Date()
    ) {
        self.percent = percent
        self.exactPercent = exactPercent ?? Double(percent)
        self.isCharging = isCharging
        self.isACConnected = isACConnected
        self.isFullyCharged = isFullyCharged
        self.cycleCount = cycleCount
        self.voltageMV = voltageMV
        self.amperageMA = amperageMA
        self.wattageW = wattageW
        self.designCapacityMAh = designCapacityMAh
        self.fullChargeCapacityMAh = fullChargeCapacityMAh
        self.remainingCapacityMAh = remainingCapacityMAh
        self.nominalCapacityMAh = nominalCapacityMAh
        self.healthPercent = healthPercent
        self.timeRemainingMinutes = timeRemainingMinutes
        self.serialNumber = serialNumber
        self.thermalState = thermalState
        self.temperatureC = temperatureC
        self.cellVoltagesMV = cellVoltagesMV
        self.notChargingReason = notChargingReason
        self.timestamp = timestamp
    }
    
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let p = try c.decodeIfPresent(Int.self, forKey: .percent) ?? 0
        self.percent = p
        self.exactPercent = try c.decodeIfPresent(Double.self, forKey: .exactPercent) ?? Double(p)
        self.isCharging = try c.decodeIfPresent(Bool.self, forKey: .isCharging) ?? false
        self.isACConnected = try c.decodeIfPresent(Bool.self, forKey: .isACConnected) ?? false
        self.isFullyCharged = try c.decodeIfPresent(Bool.self, forKey: .isFullyCharged) ?? false
        self.cycleCount = try c.decodeIfPresent(Int.self, forKey: .cycleCount) ?? 0
        self.voltageMV = try c.decodeIfPresent(Int.self, forKey: .voltageMV) ?? 0
        self.amperageMA = try c.decodeIfPresent(Int.self, forKey: .amperageMA) ?? 0
        self.wattageW = try c.decodeIfPresent(Double.self, forKey: .wattageW) ?? 0.0
        self.designCapacityMAh = try c.decodeIfPresent(Int.self, forKey: .designCapacityMAh) ?? 0
        self.fullChargeCapacityMAh = try c.decodeIfPresent(Int.self, forKey: .fullChargeCapacityMAh) ?? 0
        self.remainingCapacityMAh = try c.decodeIfPresent(Int.self, forKey: .remainingCapacityMAh) ?? 0
        self.nominalCapacityMAh = try c.decodeIfPresent(Int.self, forKey: .nominalCapacityMAh) ?? 0
        self.healthPercent = try c.decodeIfPresent(Double.self, forKey: .healthPercent) ?? 100.0
        self.timeRemainingMinutes = try c.decodeIfPresent(Int.self, forKey: .timeRemainingMinutes) ?? -1
        self.serialNumber = try c.decodeIfPresent(String.self, forKey: .serialNumber) ?? "Unknown"
        self.thermalState = try c.decodeIfPresent(String.self, forKey: .thermalState) ?? "Nominal"
        self.temperatureC = try c.decodeIfPresent(Double.self, forKey: .temperatureC)
        self.cellVoltagesMV = try c.decodeIfPresent([Int].self, forKey: .cellVoltagesMV) ?? []
        self.notChargingReason = try c.decodeIfPresent(Int.self, forKey: .notChargingReason) ?? 0
        self.timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
    }
}

public struct GovernorConfig: Codable, Equatable, Sendable {
    public var targetLimit: Int
    public var driftEnabled: Bool
    public var driftMargin: Int
    public var thermalProtectionEnabled: Bool
    public var autoServerMode: Bool
    public var pollIntervalSeconds: Double
    
    // Backwards-compatible aliases for deadband
    public var deadbandEnabled: Bool {
        get { driftEnabled }
        set { driftEnabled = newValue }
    }
    public var deadbandDelta: Int {
        get { driftMargin }
        set { driftMargin = newValue }
    }
    
    enum CodingKeys: String, CodingKey {
        case targetLimit
        case driftEnabled
        case driftMargin
        case deadbandEnabled
        case deadbandDelta
        case sailingEnabled
        case sailingDelta
        case thermalProtectionEnabled
        case autoServerMode
        case pollIntervalSeconds
    }
    
    public init(
        targetLimit: Int,
        driftEnabled: Bool,
        driftMargin: Int,
        thermalProtectionEnabled: Bool,
        autoServerMode: Bool,
        pollIntervalSeconds: Double
    ) {
        self.targetLimit = targetLimit
        self.driftEnabled = driftEnabled
        self.driftMargin = driftMargin
        self.thermalProtectionEnabled = thermalProtectionEnabled
        self.autoServerMode = autoServerMode
        self.pollIntervalSeconds = pollIntervalSeconds
    }
    
    // Legacy initializer supporting deadband naming
    public init(
        targetLimit: Int,
        deadbandEnabled: Bool,
        deadbandDelta: Int,
        thermalProtectionEnabled: Bool,
        autoServerMode: Bool,
        pollIntervalSeconds: Double
    ) {
        self.targetLimit = targetLimit
        self.driftEnabled = deadbandEnabled
        self.driftMargin = deadbandDelta
        self.thermalProtectionEnabled = thermalProtectionEnabled
        self.autoServerMode = autoServerMode
        self.pollIntervalSeconds = pollIntervalSeconds
    }
    
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.targetLimit = try c.decodeIfPresent(Int.self, forKey: .targetLimit) ?? 50
        self.driftEnabled = try c.decodeIfPresent(Bool.self, forKey: .driftEnabled)
            ?? c.decodeIfPresent(Bool.self, forKey: .deadbandEnabled)
            ?? c.decodeIfPresent(Bool.self, forKey: .sailingEnabled)
            ?? true
        self.driftMargin = try c.decodeIfPresent(Int.self, forKey: .driftMargin)
            ?? c.decodeIfPresent(Int.self, forKey: .deadbandDelta)
            ?? c.decodeIfPresent(Int.self, forKey: .sailingDelta)
            ?? 3
        self.thermalProtectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .thermalProtectionEnabled) ?? true
        self.autoServerMode = try c.decodeIfPresent(Bool.self, forKey: .autoServerMode) ?? true
        self.pollIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .pollIntervalSeconds) ?? 5.0
    }
    
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(targetLimit, forKey: .targetLimit)
        try c.encode(driftEnabled, forKey: .driftEnabled)
        try c.encode(driftMargin, forKey: .driftMargin)
        try c.encode(driftEnabled, forKey: .deadbandEnabled)
        try c.encode(driftMargin, forKey: .deadbandDelta)
        try c.encode(thermalProtectionEnabled, forKey: .thermalProtectionEnabled)
        try c.encode(autoServerMode, forKey: .autoServerMode)
        try c.encode(pollIntervalSeconds, forKey: .pollIntervalSeconds)
    }
    
    public static var `default`: GovernorConfig {
        GovernorConfig(
            targetLimit: 50,
            driftEnabled: true,
            driftMargin: 3,
            thermalProtectionEnabled: true,
            autoServerMode: true,
            pollIntervalSeconds: 5.0
        )
    }
}

public struct GovernorState: Codable, Equatable, Sendable {
    public var activeTarget: Int
    public var isChargingInhibited: Bool
    public var inDrift: Bool
    public var isThermalThrottled: Bool
    public var modeDescription: String
    public var lastActionTimestamp: Date
    public var lastActionReason: String
    public var consecutiveErrors: Int
    
    // Backwards-compatible alias for inDeadband
    public var inDeadband: Bool {
        get { inDrift }
        set { inDrift = newValue }
    }
    
    public static var initial: GovernorState {
        GovernorState(
            activeTarget: 50,
            isChargingInhibited: false,
            inDrift: false,
            isThermalThrottled: false,
            modeDescription: "Initializing",
            lastActionTimestamp: Date(),
            lastActionReason: "Daemon started",
            consecutiveErrors: 0
        )
    }
}
