import PDClientCore
import SwiftUI
import UIKit

/// The keys the iOS keyboard doesn't have, in a row above it (or at the bottom of the screen
/// with a hardware keyboard). ⌃ ⌥ ⇧ ⌘ stick: tap for the next key, double-tap to lock.
struct KeyBar: View {
    /// Pushed in by the stream view, which owns it (observation doesn't reach an input
    /// accessory's hosting controller reliably).
    var sticky = StickyModifiers()
    let tapModifier: (MacModifiers) -> Void
    let tap: (UInt16) -> Void
    let dismiss: () -> Void

    private static let modifiers: [(MacModifiers, String, String)] = [
        (.control, "⌃", "Control"), (.option, "⌥", "Option"), (.shift, "⇧", "Shift"), (.command, "⌘", "Command"),
    ]
    private static let arrows: [(UInt16, String, String)] = [
        (MacKey.left, "arrow.left", "Left"), (MacKey.up, "arrow.up", "Up"),
        (MacKey.down, "arrow.down", "Down"), (MacKey.right, "arrow.right", "Right"),
    ]
    private static let navigation: [(UInt16, String, String)] = [
        (MacKey.forwardDelete, "delete.forward", "Forward Delete"),
        (MacKey.home, "arrow.up.to.line", "Home"), (MacKey.end, "arrow.down.to.line", "End"),
        (MacKey.pageUp, "chevron.up.2", "Page Up"), (MacKey.pageDown, "chevron.down.2", "Page Down"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        key("esc", label: "Escape") { tap(MacKey.escape) }
                        key("tab", label: "Tab") { tap(MacKey.tab) }
                        ForEach(Self.modifiers, id: \.1) { modifier, glyph, name in
                            modifierKey(modifier, glyph: glyph, name: name)
                        }
                        ForEach(Self.arrows, id: \.0) { code, symbol, name in
                            key(symbol: symbol, label: name) { tap(code) }
                        }
                        ForEach(Self.navigation, id: \.0) { code, symbol, name in
                            key(symbol: symbol, label: name) { tap(code) }
                        }
                        ForEach(Array(MacKey.functionKeys.enumerated()), id: \.offset) { index, code in
                            key("F\(index + 1)", label: "F\(index + 1)") { tap(code) }
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()

            Button(action: dismiss) {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 38)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityLabel("Hide Keyboard")
            .padding(.trailing, 10)
        }
        .frame(height: 50)
        .foregroundStyle(.primary)
    }

    private func key(_ title: String? = nil, symbol: String? = nil, label: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                } else {
                    Text(title ?? "").font(.system(size: 15, weight: .medium))
                }
            }
            .frame(minWidth: 40, minHeight: 38)
            .padding(.horizontal, title.map { $0.count > 2 ? 6 : 0 } ?? 0)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
        .accessibilityLabel(label)
    }

    private func modifierKey(_ modifier: MacModifiers, glyph: String, name: String) -> some View {
        let state = sticky.state(modifier)
        return Button {
            tapModifier(modifier)
        } label: {
            Text(glyph)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(state == .off ? Color.primary : .white)
                .frame(width: 40, height: 38)
                .background(state == .off ? Color.clear : Color.accentColor, in: .rect(cornerRadius: 10))
                // Locked shows a bar under the glyph, like Caps Lock on the iOS keyboard.
                .overlay(alignment: .bottom) {
                    if state == .locked {
                        Capsule().fill(.white).frame(width: 14, height: 2.5).padding(.bottom, 5)
                    }
                }
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
        .accessibilityLabel(name)
        .accessibilityValue(state == .off ? "Off" : state == .once ? "On for the next key" : "Locked")
        .accessibilityAddTraits(state == .off ? [] : .isSelected)
    }
}

/// Hosts the bar as a text view's `inputAccessoryView`.
final class KeyBarAccessory: UIView {
    private let host: UIHostingController<KeyBar>

    var sticky: StickyModifiers {
        get { host.rootView.sticky }
        set { host.rootView.sticky = newValue }
    }

    init(_ bar: KeyBar) {
        host = UIHostingController(rootView: bar)
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 56))
        autoresizingMask = .flexibleWidth
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 56) }
}
