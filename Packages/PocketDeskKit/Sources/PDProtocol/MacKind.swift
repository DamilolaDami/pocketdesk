/// What sort of Mac a host is, so the phone can draw the right one. Advertised in the Bonjour
/// TXT record (`k`), like Apple's own `_device-info` record does with the model.
public enum MacKind: String, Codable, Sendable, CaseIterable {
    case laptop, imac, mini, studio, pro, desktop
}
