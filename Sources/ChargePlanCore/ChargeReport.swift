import Foundation

/// JSON shape shared by the daemon STATUS command and an offline status read.
/// Building this does not publish a charge ceiling.
public enum ChargeReport {
    public static func dictionary(
        battery batt: BatteryStatus,
        config: GovernorConfig,
        state: GovernorState,
        backend: String,
        enforcedSoc: Int
    ) -> [String: Any] {
        [
            "battery": [
                "percent": batt.percent,
                "exact_percent": batt.exactPercent,
                "remaining_capacity_mah": batt.remainingCapacityMAh,
                "is_charging": batt.isCharging,
                "is_ac_connected": batt.isACConnected,
                "is_fully_charged": batt.isFullyCharged,
                "cycle_count": batt.cycleCount,
                "voltage_mv": batt.voltageMV,
                "amperage_ma": batt.amperageMA,
                "wattage_w": batt.wattageW,
                "health_percent": batt.healthPercent,
                "design_capacity_mah": batt.designCapacityMAh,
                "full_capacity_mah": batt.fullChargeCapacityMAh,
                "thermal_state": batt.thermalState,
                "not_charging_reason": batt.notChargingReason,
                "serial_number": batt.serialNumber
            ],
            "governor": [
                "version": ChargePlanVersion,
                "target_limit": config.targetLimit,
                "hold_limit": state.activeTarget,
                "drift_enabled": config.driftEnabled,
                "drift_margin": config.driftMargin,
                "deadband_enabled": config.driftEnabled,
                "deadband_delta": config.driftMargin,
                "enforced_soc": enforcedSoc,
                "charging_inhibited": state.isChargingInhibited,
                "thermal_throttled": state.isThermalThrottled,
                "mode": state.modeDescription,
                "backend": backend,
                "last_action": state.lastActionReason,
                "last_action_time": ISO8601DateFormatter().string(from: state.lastActionTimestamp)
            ]
        ]
    }
}
