import PDClientCore
import SwiftUI

/// Tile colors, shared by the app and its widgets.
extension ShortcutColor {
    var tint: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: Color(red: 0.95, green: 0.72, blue: 0.0)
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: Color(white: 0.45)
        }
    }
}
