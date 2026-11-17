import Foundation
import IOKit
import IOKit.ps

public final class BatteryMonitor {
    private let lock = NSLock()
    private var cachedStatus: (at: Date, status: BatteryStatus)?
    private var smartBatteryService: io_service_t = IO_OBJECT_NULL
    private var bankServices: [io_service_t] = []
    private var packServices: [io_service_t] = []
    private var didQueryExtendedServices = false

    public init() {
        self.smartBatteryService = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
    }

    deinit {
        if smartBatteryService != IO_OBJECT_NULL {
            IOObjectRelease(smartBatteryService)
            smartBatteryService = IO_OBJECT_NULL
        }
        for svc in bankServices where svc != IO_OBJECT_NULL {
            IOObjectRelease(svc)
        }
        bankServices.removeAll()
        for svc in packServices where svc != IO_OBJECT_NULL {
            IOObjectRelease(svc)
        }
        packServices.removeAll()
    }

    public func getCurrentStatus(maxAge: TimeInterval = 0.8) -> BatteryStatus {
        let now = Date()
        if maxAge > 0 {
            lock.lock()
            if let cached = cachedStatus, now.timeIntervalSince(cached.at) < maxAge {
                let status = cached.status
                lock.unlock()
                return status
            }
            lock.unlock()
        }

        let fresh = autoreleasepool {
            readHardwareStatus(timestamp: now)
        }

        lock.lock()
        cachedStatus = (now, fresh)
        lock.unlock()
        return fresh
    }

    private func ensureSmartBatteryService() -> io_service_t {
        lock.lock()
        defer { lock.unlock() }
        if smartBatteryService == IO_OBJECT_NULL {
            smartBatteryService = IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching("AppleSmartBattery")
            )
        }
        return smartBatteryService
    }

    private static func collectServices(matching className: String) -> [io_service_t] {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iter) == kIOReturnSuccess else {
            return []
        }
        defer { IOObjectRelease(iter) }
        var services: [io_service_t] = []
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            services.append(svc)
            svc = IOIteratorNext(iter)
        }
        return services
    }

    private func ensureExtendedBatteryServices() -> (banks: [io_service_t], packs: [io_service_t]) {
        lock.lock()
        if didQueryExtendedServices {
            let banks = bankServices
            let packs = packServices
            lock.unlock()
            return (banks, packs)
        }
        lock.unlock()

        let banks = Self.collectServices(matching: "AppleSmartBatteryBank")
        let packs = Self.collectServices(matching: "AppleSmartBatteryPack")

        lock.lock()
        if didQueryExtendedServices {
            let existingBanks = bankServices
            let existingPacks = packServices
            lock.unlock()
            banks.forEach { IOObjectRelease($0) }
            packs.forEach { IOObjectRelease($0) }
            return (existingBanks, existingPacks)
        }
        didQueryExtendedServices = true
        bankServices = banks
        packServices = packs
        lock.unlock()
        return (banks, packs)
    }

    private func readHardwareStatus(timestamp: Date) -> BatteryStatus {
        var percent = 0
        var isCharging = false
        var isACConnected = false
        var isFullyCharged = false
        var timeRemaining = -1
        var serialNumber = "Unknown"

        // 1. Read IOPS (I/O Power Source)
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as [CFTypeRef]? {
            for s in sources {
                if let desc = IOPSGetPowerSourceDescription(blob, s)?.takeUnretainedValue() as? [String: Any] {
                    if let cur = desc[kIOPSCurrentCapacityKey] as? Int {
                        percent = cur
                    }
                    if let charging = desc[kIOPSIsChargingKey] as? Bool {
                        isCharging = charging
                    } else if let chargingInt = desc[kIOPSIsChargingKey] as? Int {
                        isCharging = (chargingInt != 0)
                    }
                    if let charged = desc[kIOPSIsChargedKey] as? Bool {
                        isFullyCharged = charged
                    }
                    if let state = desc[kIOPSPowerSourceStateKey] as? String {
                        isACConnected = (state == kIOPSACPowerValue)
                    }
                    if let time = desc[kIOPSTimeToEmptyKey] as? Int {
                        timeRemaining = time
                    }
                    if let serial = desc[kIOPSHardwareSerialNumberKey] as? String {
                        serialNumber = serial
                    }
                }
            }
        }

        // 2. Read AppleSmartBattery from IOKit Registry using cached service port
        var cycleCount = 0
        var voltageMV = 0
        var amperageMA = 0
        var designCapacity = 0
        var fullCapacity = 0
        var remainingCapacity = 0
        var nominalCapacity = 0
        var wattage = 0.0
        var notChargingReason = 0

        let service = ensureSmartBatteryService()
        if service != IO_OBJECT_NULL {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let dict = props?.takeRetainedValue() as? [String: Any] {

                cycleCount = dict["CycleCount"] as? Int ?? 0
                voltageMV = dict["Voltage"] as? Int ?? 0

                if let amp = dict["Amperage"] as? Int {
                    amperageMA = amp
                } else if let instAmp = dict["InstantAmperage"] as? Int {
                    amperageMA = instAmp
                }

                if let extConn = dict["ExternalConnected"] as? Bool {
                    isACConnected = extConn
                } else if let extInt = dict["ExternalConnected"] as? Int {
                    isACConnected = (extInt != 0)
                }

                if let fullyCharged = dict["FullyCharged"] as? Bool {
                    isFullyCharged = fullyCharged
                }

                if let bdata = dict["BatteryData"] as? [String: Any] {
                    designCapacity = bdata["DesignCapacity"] as? Int ?? 0
                    fullCapacity = bdata["FullChargeCapacity"] as? Int ?? 0
                    nominalCapacity = bdata["NominalChargeCapacity"] as? Int ?? 0
                    remainingCapacity = bdata["RemainingCapacity"] as? Int ?? 0
                    if percent == 0, let cap = bdata["CurrentCapacity"] as? Int {
                        percent = cap
                    }
                }

                if remainingCapacity == 0, let cur = dict["CurrentCapacity"] as? Int, cur > 100 {
                    remainingCapacity = cur
                }

                if let cdata = dict["ChargerData"] as? [String: Any] {
                    if let chg = cdata["IsCharging"] as? Int {
                        isCharging = (chg != 0)
                    }
                }

                if let reason = dict["NotChargingReason"] as? Int {
                    notChargingReason = reason
                }

                if let s = dict["Serial"] as? String, serialNumber == "Unknown" {
                    serialNumber = s
                }
            }
        }

        if voltageMV > 0 && amperageMA != 0 {
            wattage = Double(voltageMV) * Double(amperageMA) / 1_000_000.0
        }

        var health = 100.0
        if designCapacity > 0 && fullCapacity > 0 {
            health = min(100.0, (Double(fullCapacity) / Double(designCapacity)) * 100.0)
        }

        let exactPercent: Double
        if percent >= 100 {
            exactPercent = 100.0
        } else if percent > 0 && fullCapacity > 0 && remainingCapacity > 0 {
            let stepMAh = max(1.0, Double(fullCapacity) / 100.0)
            let fraction = fmod(Double(remainingCapacity), stepMAh) / stepMAh
            let clampedFraction = max(0.0, min(0.99, fraction))
            let roundedFraction = min(0.99, (clampedFraction * 100.0).rounded() / 100.0)
            exactPercent = Double(percent) + roundedFraction
        } else {
            exactPercent = Double(percent)
        }

        let thermalString: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalString = "Nominal"
        case .fair: thermalString = "Fair"
        case .serious: thermalString = "Serious (Throttled)"
        case .critical: thermalString = "Critical"
        @unknown default: thermalString = "Unknown"
        }

        // 3. Read Individual Cell Voltages and Internal Battery Temperature using cached service ports
        let extended = ensureExtendedBatteryServices()
        var cellVoltages: [Int] = []
        cellVoltages.reserveCapacity(extended.banks.count)
        for bankService in extended.banks {
            var bankProps: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(bankService, &bankProps, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let dict = bankProps?.takeRetainedValue() as? [String: Any],
               let bdata = dict["BatteryData"] as? [String: Any],
               let cellV = bdata["CellVoltage"] as? Int {
                cellVoltages.append(cellV)
            }
        }

        var tempC: Double? = nil
        for packService in extended.packs {
            var packProps: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(packService, &packProps, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let dict = packProps?.takeRetainedValue() as? [String: Any],
               let bdata = dict["BatteryData"] as? [String: Any],
               let tempRaw = bdata["Temperature"] as? Int {
                tempC = Double(tempRaw) / 100.0
            }
        }

        return BatteryStatus(
            percent: percent,
            exactPercent: exactPercent,
            isCharging: isCharging,
            isACConnected: isACConnected,
            isFullyCharged: isFullyCharged,
            cycleCount: cycleCount,
            voltageMV: voltageMV,
            amperageMA: amperageMA,
            wattageW: wattage,
            designCapacityMAh: designCapacity,
            fullChargeCapacityMAh: fullCapacity,
            remainingCapacityMAh: remainingCapacity,
            nominalCapacityMAh: nominalCapacity,
            healthPercent: (health * 10).rounded() / 10.0,
            timeRemainingMinutes: timeRemaining,
            serialNumber: serialNumber,
            thermalState: thermalString,
            temperatureC: tempC,
            cellVoltagesMV: cellVoltages,
            notChargingReason: notChargingReason,
            timestamp: timestamp
        )
    }
}
