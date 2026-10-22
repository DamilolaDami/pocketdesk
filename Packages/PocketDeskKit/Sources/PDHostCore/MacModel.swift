#if os(macOS)
import Darwin
import IOKit.ps
import PDProtocol

public enum MacModel {
    /// From `hw.model`. Apple silicon desktops share the "MacNN,N" scheme with laptops, so
    /// those go by a table, and anything unknown by whether there's a built-in battery.
    public static func current() -> MacKind {
        kind(model: hardwareModel(), hasBattery: hasInternalBattery())
    }

    static func kind(model: String, hasBattery: Bool) -> MacKind {
        if model.hasPrefix("MacBook") { return .laptop }
        if model.hasPrefix("Macmini") { return .mini }
        if model.hasPrefix("iMac") { return .imac }
        if model.hasPrefix("MacPro") { return .pro }
        if let kind = appleSilicon[model] { return kind }
        return hasBattery ? .laptop : .desktop
    }

    private static let appleSilicon: [String: MacKind] = [
        "Mac13,1": .studio, "Mac13,2": .studio, "Mac14,13": .studio, "Mac14,14": .studio,
        "Mac15,14": .studio, "Mac16,9": .studio,
        "Mac14,3": .mini, "Mac14,12": .mini, "Mac16,10": .mini, "Mac16,11": .mini,
        "Mac15,4": .imac, "Mac15,5": .imac, "Mac16,2": .imac, "Mac16,3": .imac,
        "Mac14,8": .pro,
    ]

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    private static func hasInternalBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }
}
#endif
