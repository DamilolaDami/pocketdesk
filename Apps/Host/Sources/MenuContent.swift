import PDHostCore
import PDProtocol
import PDSecurity
import SwiftUI

/// The menu bar panel.
struct MenuContent: View {
    let controller: HostController
    @State private var permissions = HostPermissions.current()
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var askBeforeConnecting = false
    @State private var sharedFolders = SharedFolders.current.enabled
    @State private var writableFolders = SharedFolders.current.writable
    /// `nil` until checked, or if `pmset` couldn't say.
    @State private var wakeForNetworkAccess: Bool?
    @Environment(\.openWindow) private var openWindow

    private var state: HostState { controller.store.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if controller.updater.state.isBusy {
                Panel {
                    PanelRow(title: controller.updater.state.phase == .installing ? "Installing update…" : "Checking for updates…") {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            if !permissions.allGranted {
                PermissionsPanel(permissions: permissions)
            }

            if permissions.allGranted, wakeForNetworkAccess == false {
                WakeHint()
            }

            if let approval = state.pendingApprovals.first {
                ApprovalCard(approval: approval) { accepted in
                    Task { await controller.resolveApproval(approval.id, accepted: accepted) }
                }
            }

            if !state.connected.isEmpty {
                Panel(title: "Connected") {
                    ForEach(state.connected) { phone in
                        SessionRow(phone: phone) {
                            Task { await controller.disconnect(phone.id) }
                        }
                    }
                }
            }

            keepAwakePanel
            virtualDisplayPanel

            if !state.pairedPeers.isEmpty {
                Panel(title: "Paired Phones") {
                    ForEach(state.pairedPeers) { peer in
                        PairedPhoneRow(peer: peer, isConnected: state.connected.contains { $0.id == peer.fingerprint }) {
                            Task { await controller.revoke(peer.fingerprint) }
                        }
                    }
                }
            }

            footer
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { askBeforeConnecting = controller.askBeforeConnecting }
        // Grants happen in System Settings; keep the panel in step while it's open.
        .task {
            while !Task.isCancelled {
                permissions = .current()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task {
            while !Task.isCancelled {
                wakeForNetworkAccess = await Task.detached { WakeAddresses.wakeForNetworkAccess() }.value
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 36, trimsMargin: true)
            VStack(alignment: .leading, spacing: 1) {
                Text("PocketDesk").font(.headline)
                HStack(spacing: 5) {
                    StatusDot(color: statusColor)
                    Text(statusText).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            settingsMenu
        }
        .padding(.horizontal, HostMetrics.inset)
        .padding(.top, 2)
    }

    private var statusText: String {
        switch state.listening {
        case .starting: "Starting…"
        case .listening:
            if state.connected.count > 1 { "\(state.connected.count) phones connected" }
            else if !state.connected.isEmpty { "Phone connected" }
            else if !permissions.allGranted { "Needs permissions" }
            else { "Ready" }
        case .stopped(let error): error == nil ? "Stopped" : "Couldn't start"
        }
    }

    private var statusColor: Color {
        switch state.listening {
        case .starting: .yellow
        case .listening: permissions.allGranted ? .green : .orange
        case .stopped: .red
        }
    }

    private var footer: some View {
        Button {
            openWindow(id: PairingWindow.id)
            NSApplication.shared.activate()
        } label: {
            Text("Pair a Phone…").frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("Launch at Login", isOn: Binding(get: { launchAtLogin }, set: { enabled in
                try? LaunchAtLogin.set(enabled)
                launchAtLogin = LaunchAtLogin.isEnabled
            }))
            Toggle("Ask Before Each Connection", isOn: Binding(get: { askBeforeConnecting }, set: { ask in
                controller.askBeforeConnecting = ask
                askBeforeConnecting = ask
            }))
            // Paired phones can browse these and fetch files from them.
            Menu("Share Files with Phones") {
                ForEach(SharedFolder.allCases, id: \.self) { folder in
                    Toggle(folder.name, isOn: Binding(get: { sharedFolders.contains(folder) }, set: { shared in
                        SharedFolders.setShared(folder, shared)
                        sharedFolders = SharedFolders.current.enabled
                        writableFolders = SharedFolders.current.writable
                        // Reading it now brings up macOS's "allow access" prompt while
                        // you're here, not later while you're away using your phone.
                        if shared, let url = SharedFolders.userLocations[folder] {
                            _ = try? FileManager.default.contentsOfDirectory(atPath: url.path)
                        }
                    }))
                }
                Divider()
                Menu("Allow File Changes") {
                    Text("Allows creating folders, renaming, moving and using Trash.")
                    ForEach(SharedFolder.allCases, id: \.self) { folder in
                        Toggle(folder.name, isOn: Binding(get: { writableFolders.contains(folder) }, set: { writable in
                            SharedFolders.setWritable(folder, writable)
                            writableFolders = SharedFolders.current.writable
                        }))
                        .disabled(!sharedFolders.contains(folder))
                    }
                }
            }
            Divider()
            Button("Check for Updates…") { controller.updater.checkForUpdates() }
                .disabled(!controller.updater.canCheck)
            Toggle("Check for Updates Automatically", isOn: Binding(
                get: { controller.updater.automaticallyChecks },
                set: { controller.updater.automaticallyChecks = $0 }))
            Divider()
            Button("Remote Access…") {
                openWindow(id: RelaySettingsWindow.id)
                NSApplication.shared.activate()
            }
            Button("Show Welcome…") {
                openWindow(id: OnboardingWindow.id)
                NSApplication.shared.activate()
            }
            Button("Quit PocketDesk") {
                Task {
                    await controller.stop()
                    NSApplication.shared.terminate(nil)
                }
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
    }

    private var keepAwakePanel: some View {
        let keepAwake = state.keepAwake
        return Panel(title: "Keep Mac Available",
                     footer: "Prevents idle sleep. The display can still turn off, and Sleep still works.") {
            SwitchRow(title: "While Streaming", isOn: Binding(
                get: { keepAwake.settings.whileStreaming },
                set: { enabled in
                    var settings = keepAwake.settings
                    settings.whileStreaming = enabled
                    Task { await controller.setKeepAwakeSettings(settings) }
                }))
            SwitchRow(title: "Allow on Battery", isOn: Binding(
                get: { keepAwake.settings.allowOnBattery },
                set: { enabled in
                    var settings = keepAwake.settings
                    settings.allowOnBattery = enabled
                    Task { await controller.setKeepAwakeSettings(settings) }
                }))
            if keepAwake.hasRequest {
                PanelRow(title: keepAwake.waitingForPower ? "Waiting for power" : "Keeping awake",
                         subtitle: keepAwake.remainingSeconds > 0
                            ? "\(Duration.seconds(keepAwake.remainingSeconds).formatted(.time(pattern: .hourMinuteSecond))) remaining"
                            : nil) {
                    Button("End") { Task { await controller.endKeepAwake() } }
                        .controlSize(.small)
                }
            } else {
                PanelRow(title: "Keep Available For") {
                    Menu("Choose") {
                        Button("15 Minutes") { keepAvailable(15 * 60) }
                        Button("1 Hour") { keepAvailable(3600) }
                        Button("2 Hours") { keepAvailable(2 * 3600) }
                        Button("4 Hours") { keepAvailable(4 * 3600) }
                        Button("8 Hours") { keepAvailable(8 * 3600) }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            if let error = keepAwake.error {
                ProblemRow(text: error)
            }
        }
    }

    private var virtualDisplayPanel: some View {
        let display = state.virtualDisplay
        return Panel(title: "Virtual Display", note: "Experimental",
                     footer: "A temporary extra workspace, removed when its viewing session ends. Physical screens stay on.") {
            SwitchRow(title: "Allow Virtual Displays", isOn: Binding(get: { display.enabled }, set: { enabled in
                Task { await controller.setVirtualDisplaysEnabled(enabled) }
            }))
            .disabled(!display.available && !display.enabled)

            if let active = display.active {
                PanelRow(title: active.owner.name,
                         subtitle: display.phase == .configuring
                            ? "Applying workspace size…"
                            : "\(active.mode.width)×\(active.mode.height) · \(active.mode.scale)× · \(active.mode.refreshRate) Hz") {
                    Button(display.phase == .cleanupFailed ? "Retry" : "End") {
                        Task { await controller.endVirtualDisplay(active.id) }
                    }
                    .controlSize(.small)
                    .disabled(display.phase == .ending)
                }
            } else if display.phase == .creating {
                PanelRow(title: "Creating workspace…") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { Task { await controller.cancelVirtualDisplay() } }
                            .controlSize(.small)
                    }
                }
            } else if display.enabled && display.available {
                if display.viewers.isEmpty {
                    PanelRow(title: "No phone viewing", subtitle: "View this Mac from a phone to create its workspace.")
                } else {
                    ForEach(display.viewers) { viewer in
                        PanelRow(title: viewer.name,
                                 subtitle: "Since \(viewer.connectedAt.formatted(date: .omitted, time: .shortened)) · 1280×800 · 60 Hz") {
                            Button("Create") {
                                Task { await controller.createVirtualDisplay(for: viewer.id, mode: .standard) }
                            }
                            .controlSize(.small)
                            .disabled(display.suspended)
                        }
                    }
                }
            }
            if let reason = display.unavailableReason {
                PanelRow(title: "Unavailable", subtitle: reason)
            }
            if let error = display.error {
                ProblemRow(text: error)
            }
        }
    }

    private func keepAvailable(_ seconds: Int) {
        Task { await controller.keepAvailable(for: seconds) }
    }
}

private struct PermissionsPanel: View {
    let permissions: HostPermissions

    var body: some View {
        Panel(title: "Allow Access") {
            row(.screenRecording, title: "Screen Recording", detail: "Shows your screen on the phone")
            row(.accessibility, title: "Accessibility", detail: "Lets the phone click and type")
        }
    }

    private func row(_ kind: HostPermissions.Kind, title: String, detail: String) -> some View {
        PanelRow(title: title, subtitle: detail) {
            if permissions.isGranted(kind) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Allowed")
            } else {
                Button("Open…") { HostPermissions.request(kind) }
                    .controlSize(.small)
            }
        }
    }
}

/// "Wake for network access" is off, so a phone can't wake this Mac from sleep.
private struct WakeHint: View {
    var body: some View {
        Panel {
            PanelRow(title: "Let your phone wake this Mac",
                     subtitle: "Turn on “Wake for network access” in Battery › Options (Energy on desktops).") {
                Button("Open…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

/// Something that went wrong, in a `Panel`.
private struct ProblemRow: View {
    let text: String

    var body: some View {
        PanelRow(title: "Something went wrong", subtitle: text) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        }
    }
}

private struct SessionRow: View {
    let phone: HostState.ConnectedPhone
    let disconnect: () -> Void

    var body: some View {
        PanelRow(title: phone.deviceName, subtitle: detail) {
            Button("Disconnect", action: disconnect)
                .controlSize(.small)
                .help("End this session; the phone is told the Mac ended it.")
        }
    }

    private var detail: String {
        guard let stream = phone.stream else { return "Connecting…" }
        let source = phone.window.map { "\($0.appName) window" } ?? "Whole screen"
        return "\(source) · \(stream.width)×\(stream.height) · \(stream.fps) fps"
    }
}

private struct PairedPhoneRow: View {
    let peer: PairedPeer
    let isConnected: Bool
    let forget: () -> Void
    @State private var hovering = false

    var body: some View {
        PanelRow(title: peer.name,
                 subtitle: isConnected ? "Connected" : "Paired \(peer.pairedAt.formatted(.relative(presentation: .named)))") {
            ZStack(alignment: .trailing) {
                Button("Forget", role: .destructive, action: forget)
                    .controlSize(.small)
                    .opacity(hovering ? 1 : 0)
                if isConnected && !hovering {
                    StatusDot(color: .green).accessibilityLabel("Connected")
                }
            }
        }
        .contentShape(.rect)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { self.hovering = hovering } }
    }
}

/// A phone waiting for the person at the Mac to confirm its code.
struct ApprovalCard: View {
    let approval: PairingApproval
    let decide: (Bool) -> Void

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(approval.code == nil ? "“\(approval.deviceName)” wants to view this Mac"
                                              : "“\(approval.deviceName)” wants to pair")
                        .font(.callout.weight(.semibold))
                    Text(approval.code == nil ? "It will see your screen and can use the mouse and keyboard."
                                              : "Accept only if your phone shows this code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let code = approval.code {
                    CodeTiles(code: code, size: 30)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                HStack(spacing: 8) {
                    Button(role: .cancel) { decide(false) } label: {
                        Text(approval.isConnectionRequest ? "Deny" : "Decline").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    Button { decide(true) } label: {
                        Text(approval.isConnectionRequest ? "Allow" : "Accept").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
            .padding(HostMetrics.inset)
        }
    }
}
