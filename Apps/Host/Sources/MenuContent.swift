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
        VStack(alignment: .leading, spacing: 12) {
            header

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

            ForEach(state.connected) { phone in
                SessionPanel(phone: phone) {
                    Task { await controller.disconnect(phone.id) }
                }
            }

            keepAwakePanel
            virtualDisplayPanel

            if !state.pairedPeers.isEmpty {
                Panel(title: "Paired phones") {
                    ForEach(state.pairedPeers) { peer in
                        PairedPhoneRow(peer: peer, isConnected: state.connected.contains { $0.id == peer.fingerprint }) {
                            Task { await controller.revoke(peer.fingerprint) }
                        }
                    }
                }
            }

            footer
        }
        .padding(14)
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
            AppGlyph(size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("PocketDesk").font(.headline)
                HStack(spacing: 6) {
                    StatusDot(color: statusColor)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var statusText: String {
        switch state.listening {
        case .starting: "Starting…"
        case .listening:
            if !state.connected.isEmpty { "\(state.connected.count) phone connected" }
            else if !permissions.allGranted { "Needs permissions" }
            else { "Ready for your phone" }
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
        HStack {
            Button {
                openWindow(id: PairingWindow.id)
                NSApplication.shared.activate()
            } label: {
                Label("Pair a Phone…", systemImage: "qrcode")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(HostBrand.accent)
            .controlSize(.large)

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
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .controlSize(.large)
            .fixedSize()
        }
    }

    private var keepAwakePanel: some View {
        Panel(title: "Keep this Mac available", tint: state.keepAwake.isActive ? HostBrand.accent : nil) {
            Toggle("While streaming", isOn: Binding(
                get: { state.keepAwake.settings.whileStreaming },
                set: { enabled in
                    var settings = state.keepAwake.settings
                    settings.whileStreaming = enabled
                    Task { await controller.setKeepAwakeSettings(settings) }
                }))
                .font(.callout)
            Toggle("Allow on battery", isOn: Binding(
                get: { state.keepAwake.settings.allowOnBattery },
                set: { enabled in
                    var settings = state.keepAwake.settings
                    settings.allowOnBattery = enabled
                    Task { await controller.setKeepAwakeSettings(settings) }
                }))
                .font(.callout)

            HStack {
                Menu("Keep Available for…") {
                    Button("15 Minutes") { keepAvailable(15 * 60) }
                    Button("1 Hour") { keepAvailable(3600) }
                    Button("2 Hours") { keepAvailable(2 * 3600) }
                    Button("4 Hours") { keepAvailable(4 * 3600) }
                    Button("8 Hours") { keepAvailable(8 * 3600) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer(minLength: 0)
                if state.keepAwake.hasRequest {
                    Button("End Now") { Task { await controller.endKeepAwake() } }
                        .buttonStyle(.borderless)
                }
            }
            .font(.callout)

            if let error = state.keepAwake.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else if state.keepAwake.hasRequest {
                VStack(alignment: .leading, spacing: 3) {
                    Label(state.keepAwake.waitingForPower ? "Waiting for external power" : "Keeping Mac awake",
                          systemImage: state.keepAwake.isActive ? "cup.and.saucer.fill" : "battery.25percent")
                        .font(.caption.weight(.medium))
                    if state.keepAwake.remainingSeconds > 0 {
                        Text("\(Duration.seconds(state.keepAwake.remainingSeconds).formatted(.time(pattern: .hourMinuteSecond))) remaining")
                            .font(.caption).monospacedDigit()
                    }
                }
            }

            Text("Prevents idle sleep; your display can turn off. Battery use may increase. Sleep from the Apple menu and closing the lid still work.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var virtualDisplayPanel: some View {
        let display = state.virtualDisplay
        return Panel(title: "Virtual display · Experimental", tint: display.active == nil ? nil : HostBrand.accent) {
            Toggle("Allow Virtual Displays", isOn: Binding(get: { display.enabled }, set: { enabled in
                Task { await controller.setVirtualDisplaysEnabled(enabled) }
            }))
            .font(.callout)
            .disabled(!display.available && !display.enabled)

            if let active = display.active {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(active.owner.name).font(.callout.weight(.medium))
                        if display.phase == .configuring {
                            HStack { ProgressView().controlSize(.mini); Text("Applying workspace size…").font(.caption) }
                        }
                        Text("\(active.mode.width)×\(active.mode.height) · \(active.mode.scale)× · \(active.mode.refreshRate) Hz")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(display.phase == .cleanupFailed ? "Retry End" : "End") {
                        Task { await controller.endVirtualDisplay(active.id) }
                    }
                    .disabled(display.phase == .ending)
                }
            } else if display.phase == .creating {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Creating workspace…").font(.caption)
                    Spacer()
                    Button("Cancel") { Task { await controller.cancelVirtualDisplay() } }
                }
            } else if display.enabled && display.available {
                if display.viewers.isEmpty {
                    Text("Start viewing this Mac from a phone, then create its workspace here.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("1280×800 · 60 Hz · 1×").font(.caption).foregroundStyle(.secondary)
                    ForEach(display.viewers) { viewer in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(viewer.name).font(.callout)
                                Text("Viewing since \(viewer.connectedAt.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Create") {
                                Task { await controller.createVirtualDisplay(for: viewer.id, mode: .standard) }
                            }
                            .disabled(display.suspended)
                        }
                    }
                }
            }
            if let reason = display.unavailableReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            if let error = display.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("A temporary extra Mac workspace, removed when its viewing session ends. Physical screens stay on.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func keepAvailable(_ seconds: Int) {
        Task { await controller.keepAvailable(for: seconds) }
    }
}

private struct PermissionsPanel: View {
    let permissions: HostPermissions

    var body: some View {
        Panel(tint: .orange) {
            Label("Allow PocketDesk to share this Mac", systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
            row(.screenRecording, title: "Screen Recording", detail: "Shows your screen on the phone")
            row(.accessibility, title: "Accessibility", detail: "Lets the phone click and type")
        }
    }

    private func row(_ kind: HostPermissions.Kind, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: permissions.isGranted(kind) ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(permissions.isGranted(kind) ? .green : .secondary)
                .font(.title3)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !permissions.isGranted(kind) {
                Button("Open") { HostPermissions.request(kind) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
    }
}

/// "Wake for network access" is off, so a phone can't wake this Mac from sleep.
private struct WakeHint: View {
    var body: some View {
        Panel {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "power.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Let your phone wake this Mac").font(.callout.weight(.semibold))
                    Text("Turn on “Wake for network access” in Battery › Options (Energy on desktops).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
        }
    }
}

private struct SessionPanel: View {
    let phone: HostState.ConnectedPhone
    let disconnect: () -> Void

    var body: some View {
        Panel(tint: .green) {
            HStack(spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                VStack(alignment: .leading, spacing: 2) {
                    Text(phone.deviceName).font(.callout.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Disconnect", role: .destructive, action: disconnect)
                    .buttonStyle(.glass)
                    .tint(.red)
                    .controlSize(.small)
                    .help("End this session; the phone is told the Mac ended it.")
            }
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
        HStack(spacing: 10) {
            Image(systemName: "iphone").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.name).font(.callout)
                Text(isConnected ? "Connected now" : "Paired \(peer.pairedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(isConnected ? .green : .secondary)
            }
            Spacer()
            if hovering {
                Button("Forget", role: .destructive, action: forget)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .transition(.opacity)
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
        Panel(tint: HostBrand.accent) {
            if let code = approval.code {
                Label("“\(approval.deviceName)” wants to pair", systemImage: "iphone.badge.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                Text("Accept only if your phone shows this code:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CodeTiles(code: code, size: 30)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } else {
                Label("“\(approval.deviceName)” wants to view this Mac", systemImage: "iphone.badge.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                Text("It will see your screen and can use the mouse and keyboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(approval.isConnectionRequest ? "Deny" : "Decline", role: .cancel) { decide(false) }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                Button(approval.isConnectionRequest ? "Allow" : "Accept") { decide(true) }
                    .buttonStyle(.glassProminent)
                    .tint(HostBrand.accent)
                    .keyboardShortcut(.defaultAction)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }
}
