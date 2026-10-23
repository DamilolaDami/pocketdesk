import PDProtocol

extension StreamQuality {
    /// Low Power Mode means Battery Saver, whatever was chosen.
    public static func effective(preferred: StreamQuality, lowPowerMode: Bool) -> StreamQuality {
        lowPowerMode ? .batterySaver : preferred
    }
}
