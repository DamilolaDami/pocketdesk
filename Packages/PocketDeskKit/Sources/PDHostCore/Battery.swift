#if os(macOS)
import Foundation
import IOKit.ps
import PDProtocol

/// The internal battery, for the phone's Mac cards. `nil` on Macs without one.
enum BatteryReader {
    static func current() -> MacBattery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let descriptions = sources.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return parse(descriptions)
    }

    /// The internal battery among the power sources (UPSes and accessories are skipped).
    static func parse(_ sources: [[String: Any]]) -> MacBattery? {
        guard let battery = sources.first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }),
              let current = battery[kIOPSCurrentCapacityKey] as? Int,
              let max = battery[kIOPSMaxCapacityKey] as? Int, max > 0 else { return nil }
        return MacBattery(level: Swift.min(100, Swift.max(0, current * 100 / max)),
                          isCharging: battery[kIOPSIsChargingKey] as? Bool ?? false,
                          onPower: battery[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
    }
}
#endif
