import PDHostCore
import SwiftUI

/// First run: one step at a time, each with one thing to do. Opens on launch until finished,
/// and again from the menu ("Show Welcome…").
struct OnboardingWindow: View {
    static let id = "welcome"
    /// Set once the last step is finished; until then the window opens at launch.
    static let finishedKey = "onboardingFinished"

    let controller: HostController
    @State private var step = OnboardingStep.welcome
    @State private var forward = true
    @State private var permissions = HostPermissions.current()
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    /// `nil` until checked, or if `pmset` couldn't say.
    @State private var wakeForNetworkAccess: Bool?
    @AppStorage(Self.finishedKey) private var finished = false
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(step)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            footer
        }
        .frame(width: 640, height: 600)
        .background(.windowBackground)
        .onAppear { NSApplication.shared.activate() }
        // Grants happen in System Settings: tick them off live.
        .task {
            while !Task.isCancelled {
                permissions = .current()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task(id: step) {
            guard step == .wakeAndLogin else { return }
            while !Task.isCancelled {
                wakeForNetworkAccess = await Task.detached { WakeAddresses.wakeForNetworkAccess() }.value
                launchAtLogin = LaunchAtLogin.isEnabled
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Pages

    @ViewBuilder private func page(_ step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            Page(title: "Your Mac, in your pocket",
                 text: "Use this Mac from your iPhone: see its screen, click, type, play music and send files, from the sofa or the next room.") {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)
            }
        case .screenRecording:
            permissionPage(.screenRecording, symbol: "rectangle.inset.filled.and.person.filled",
                           title: "Let your iPhone see this screen",
                           text: "PocketDesk needs Screen Recording to show this Mac on your phone. Your screen goes only to phones you've paired, and only while one is connected.")
        case .accessibility:
            permissionPage(.accessibility, symbol: "cursorarrow.click.2",
                           title: "Let your iPhone click and type",
                           text: "Accessibility lets your taps and typing reach this Mac as clicks and keystrokes, and lets the phone show this Mac's menus.")
        case .wakeAndLogin:
            Page(titleFirst: true, title: "Ready whenever you are",
                 text: "Keep PocketDesk running, and let your phone wake this Mac when it's asleep.") {
                VStack(spacing: 12) {
                    SettingRow(symbol: "power", title: "Open at Login",
                               detail: "PocketDesk starts with your Mac, so your phone can always find it.") {
                        Toggle("Open at Login", isOn: Binding(get: { launchAtLogin }, set: { enabled in
                            try? LaunchAtLogin.set(enabled)
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    SettingRow(symbol: "moon.zzz.fill", title: "Wake for Network Access",
                               detail: wakeDetail) {
                        if wakeForNetworkAccess == true {
                            Text("On").foregroundStyle(.secondary)
                        } else {
                            Button("Open Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .frame(width: 460)
            }
        case .pair:
            PairingWindow(controller: controller, compact: true)
        case .done:
            Page(titleFirst: true, title: "You're all set",
                 text: "PocketDesk lives in the menu bar. Open the app on your iPhone and tap this Mac.") {
                VStack(spacing: 18) {
                    MenuBarHint()
                    Grid(horizontalSpacing: 24, verticalSpacing: 8) {
                        GridRow {
                            Tip(symbol: "hand.tap.fill", text: "Tap to click, hold to right-click")
                            Tip(symbol: "hand.draw.fill", text: "Two fingers to scroll")
                        }
                        GridRow {
                            Tip(symbol: "plus.magnifyingglass", text: "Pinch to zoom; it follows your typing")
                            Tip(symbol: "menubar.rectangle", text: "This Mac's menus, on your phone")
                        }
                    }
                    .frame(width: 480)
                }
            }
        }
    }

    private func permissionPage(_ kind: HostPermissions.Kind, symbol: String, title: String, text: String) -> some View {
        let granted = permissions.isGranted(kind)
        return Page(title: title, text: text) {
            Image(systemName: symbol)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
                .frame(height: 90)
        } action: {
            if granted {
                Label("Allowed", systemImage: "checkmark")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    HostPermissions.request(kind)
                } label: {
                    Label("Open System Settings", systemImage: "gearshape")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private var wakeDetail: String {
        switch wakeForNetworkAccess {
        case true?: "On: your phone can wake this Mac from sleep."
        default: "Turn it on in Battery › Options (Energy on desktops) so your phone can wake this Mac."
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let previous = step.previous {
                Button("Back") { go(to: previous) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            Spacer()
            Button(primaryTitle) { primary() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .overlay { StepDots(current: step) }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .padding(.top, 8)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .done: "Done"
        case .pair: controller.store.state.pairedPeers.isEmpty ? "Skip for Now" : "Continue"
        default:
            if let permission = step.permission, !permissions.isGranted(permission) { "Skip for Now" } else { "Continue" }
        }
    }

    private func primary() {
        guard let next = step.advanced(granted: permissions.isGranted) else {
            finished = true
            dismissWindow(id: Self.id)
            return
        }
        go(to: next)
    }

    private func go(to target: OnboardingStep) {
        forward = target > step
        withAnimation(.spring(duration: 0.55, bounce: 0.15)) { step = target }
    }
}

/// One step: an illustration, a big title, a line or two, and an optional action.
private struct Page<Art: View, Action: View>: View {
    /// Pages whose art is a list of things to read lead with the title instead.
    var titleFirst = false
    let title: String
    let text: String
    @ViewBuilder var art: Art
    @ViewBuilder var action: Action

    init(titleFirst: Bool = false, title: String, text: String, @ViewBuilder art: () -> Art,
         @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.titleFirst = titleFirst
        self.title = title
        self.text = text
        self.art = art()
        self.action = action()
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            if titleFirst {
                heading
                art.padding(.top, 6)
            } else {
                art
                heading
            }
            action
            Spacer(minLength: 10)
        }
        .padding(.horizontal, 40)
    }

    private var heading: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 28, weight: .semibold))
            Text(text)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 470)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
    }
}

private struct SettingRow<Accessory: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10, style: .continuous))
    }
}

private struct Tip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(text).font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A sketch of the menu bar, pointing at where PocketDesk lives.
private struct MenuBarHint: View {
    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            ForEach(["wifi", "battery.75percent"], id: \.self) { Image(systemName: $0).foregroundStyle(.secondary) }
            Image(systemName: "iphone")
                .frame(width: 28, height: 22)
                .background(.quaternary, in: .rect(cornerRadius: 5))
            Text("Fri 9:41").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(width: 340, height: 30)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}

private struct StepDots: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Capsule()
                    .fill(step == current ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                    .frame(width: 7, height: 7)
            }
        }
        .animation(.spring(duration: 0.4), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }
}
