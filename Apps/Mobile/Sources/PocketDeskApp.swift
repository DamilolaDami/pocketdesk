import PDClientCore
import SwiftUI

@main
struct PocketDeskApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = AppModel.controller
    @AppStorage(SettingsKey.defaultMac) private var defaultMacID = ""
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PocketDeskShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootView(controller: controller)
                .tint(Brand.accent)
                .onOpenURL { url in open(url) }
        }
        // Locked Macs ask again once PocketDesk has left the screen (not for Face ID's own
        // prompt, which only makes it inactive).
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: controller.appLeftScreen()
            case .active: controller.checkLockOnReturn()
            default: break
            }
        }
    }

    /// Pairing links, and `pocketdesk://run?id=…` from widgets and Control Center: run the
    /// shortcut, connecting (and showing the stream) first if needed.
    private func open(_ url: URL) {
        if url.scheme == "pocketdesk", url.host() == "add" {
            guard let shortcut = Shortcut(sharingURL: url) else {
                controller.store.post(notice: "That link isn't a shortcut PocketDesk can add.")
                return
            }
            controller.store.offer(imported: shortcut)
            return
        }
        if let id = Shortcut.id(fromRunURL: url) {
            guard let shortcut = controller.store.shortcuts.first(where: { $0.id == id }) else {
                controller.store.post(notice: "That shortcut isn't in PocketDesk any more.")
                return
            }
            let preferred = UUID(uuidString: defaultMacID)
            // Opened cold from a widget, discovery has only just started: give it a moment.
            controller.startDiscovery()
            Task {
                for _ in 0..<20 where controller.shortcutTarget(preferredHostID: preferred) == nil {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                controller.run(shortcut, preferredHostID: preferred)
            }
            return
        }
        try? controller.pair(using: url)
    }
}

struct RootView: View {
    let controller: SessionController
    @Environment(\.displayScale) private var displayScale
    @AppStorage(SettingsKey.haptics) private var haptics = true
    @AppStorage(PhoneOnboarding.finishedKey) private var setupFinished = false
    @State private var setup: PhoneOnboarding

    init(controller: SessionController) {
        self.controller = controller
        _setup = State(initialValue: PhoneOnboarding(
            finished: UserDefaults.standard.bool(forKey: PhoneOnboarding.finishedKey),
            hasPairedMacs: controller.hasPairedMacs))
    }

    private var state: SessionState { controller.store.state }

    var body: some View {
        GeometryReader { geometry in
            content
                .onAppear {
                    let size = geometry.size
                    controller.viewport = .init(width: size.width == 0 ? 402 : size.width,
                                                height: size.height == 0 ? 874 : size.height, scale: displayScale)
                    controller.deviceName = UIDevice.current.name
                }
        }
        .overlay(alignment: .top) {
            // Files on their way to a Mac, from any screen (and the share sheet's handoff).
            TransfersBanner(transfers: controller.store.transfers)
                .opacity(controller.store.notice == nil ? 1 : 0)
                .animation(.smooth, value: controller.store.transfers.isEmpty)
        }
        .overlay(alignment: .top) {
            if let notice = controller.store.notice {
                NoticeBanner(notice: notice)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: notice.id) {
                        try? await Task.sleep(for: .seconds(4))
                        controller.store.dismiss(notice)
                    }
                    .onTapGesture { controller.store.dismiss(notice) }
            }
        }
        .animation(.smooth(duration: 0.35), value: phase)
        .animation(.bouncy, value: controller.store.notice)
        .sensoryFeedback(trigger: isStreaming) { _, streaming in haptics && streaming ? .success : nil }
        .sensoryFeedback(trigger: controller.store.notice) { _, notice in
            guard haptics, let notice else { return nil }
            return notice.kind == .done ? .success : .warning
        }
        .task {
            // Migrate existing installs once, even if their last Mac is forgotten later.
            if controller.hasPairedMacs { setupFinished = true }
            // New users reach discovery deliberately, after the Local Network explanation.
            if !setup.isPresented { controller.startDiscovery() }
        }
        .onOpenURL { url in
            if setup.isPresented, url.scheme == "pocketdesk", url.host == "pair" { setup.findMac() }
        }
        .onChange(of: state) { _, state in
            let wasSettingUp = setup.isPresented
            setup.receive(state)
            if case .streaming = state, wasSettingUp { setupFinished = true }
        }
        .sheet(isPresented: Binding(get: { setup.showsControls }, set: { if !$0 { setup.dismissControls() } })) {
            NavigationStack {
                ControlsGuideView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { setup.dismissControls() }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        // A shortcut set to ask first (Quit, Sleep…): a tap that wasn't meant does nothing.
        .confirmationDialog(controller.store.confirmRequest.map { "Run “\($0.shortcut.name)”?" } ?? "",
                            isPresented: Binding(
                                get: { controller.store.confirmRequest != nil },
                                set: { if !$0 { controller.store.clearConfirmRequest() } }),
                            titleVisibility: .visible, presenting: controller.store.confirmRequest) { request in
            Button("Run") {
                controller.store.clearConfirmRequest()
                controller.run(request.shortcut, preferredHostID: request.preferredHostID, confirmed: true)
            }
            Button("Cancel", role: .cancel) { controller.store.clearConfirmRequest() }
        } message: { request in
            Text(request.shortcut.action.summary)
        }
        // A search shortcut, from a tile, widget or the stream: ask, then run it.
        .alert(controller.store.textRequest?.shortcut.name ?? "", isPresented: Binding(
            get: { controller.store.textRequest != nil },
            set: { if !$0 { controller.store.clearTextRequest() } }
        ), presenting: controller.store.textRequest) { request in
            TextRequestFields(controller: controller, request: request)
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .idle, .discovering:
            // Idle only lasts until discovery starts on appear.
            Group {
                if setup.isPresented {
                    PhoneSetupView(controller: controller, hosts: hosts, flow: $setup, finish: finishSetup)
                } else {
                    MainTabs(controller: controller, hosts: hosts) {
                        setup = PhoneOnboarding(finished: false, hasPairedMacs: false)
                    }
                }
            }
                .transition(.opacity)
        case .pairing(let host, let code):
            NavigationStack {
                PairingView(controller: controller, host: host, code: code)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        case .connecting(let host):
            ConnectingView(hostName: host.name, kind: host.kind) { controller.disconnect() }
                .transition(.opacity)
        case .streaming(let host, let config, _):
            StreamScreen(controller: controller, hostName: host.name, config: config)
                .transition(.opacity)
        case .failed(let message):
            FailedView(message: message, canRetry: controller.lastHost?.isPaired == true,
                       retry: { controller.retry() }, back: { controller.disconnect() })
                .transition(.opacity)
        }
    }

    private func finishSetup() {
        setup.dismiss()
        setupFinished = true
        controller.startDiscovery()
    }

    private var hosts: [DiscoveredHost] {
        if case .discovering(let hosts) = state { hosts } else { [] }
    }

    private var isStreaming: Bool {
        if case .streaming = state { true } else { false }
    }

    /// Animates only between screens, not on every in-screen state change.
    private var phase: Int {
        switch state {
        case .idle, .discovering: 1
        case .pairing: 2
        case .connecting: 3
        case .streaming: 4
        case .failed: 5
        }
    }
}

enum AppTab: String {
    case macs, shortcuts, settings
}

/// Home: the tab bar. Pairing, connecting and streaming take over the whole screen.
struct MainTabs: View {
    let controller: SessionController
    let hosts: [DiscoveredHost]
    let showSetup: () -> Void
    @SceneStorage("tab") private var tab = AppTab.macs

    var body: some View {
        TabView(selection: $tab) {
            Tab("Macs", systemImage: "laptopcomputer", value: .macs) {
                HostListView(controller: controller, hosts: hosts)
            }
            Tab("Shortcuts", systemImage: "square.grid.2x2.fill", value: .shortcuts) {
                ShortcutsView(controller: controller)
            }
            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                SettingsView(controller: controller, hosts: hosts, showSetup: showSetup)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // A shared shortcut opens where shortcuts live.
        .onChange(of: controller.store.importedShortcut) { _, imported in
            if imported != nil { tab = .shortcuts }
        }
        .onAppear { if controller.store.importedShortcut != nil { tab = .shortcuts } }
    }
}

/// The prompt's field and buttons; `Run` stays off until something's typed.
private struct TextRequestFields: View {
    let controller: SessionController
    let request: TextRequest
    @State private var text = ""

    var body: some View {
        TextField("What to look for", text: $text)
            .submitLabel(.go)
            .onSubmit(run)
        Button("Run", action: run)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut(.defaultAction)
        Button("Cancel", role: .cancel) { controller.store.clearTextRequest() }
    }

    private func run() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        controller.store.clearTextRequest()
        controller.run(request.shortcut, preferredHostID: request.preferredHostID, text: words)
    }
}

private struct NoticeBanner: View {
    let notice: Notice

    var body: some View {
        Label(notice.text, systemImage: notice.kind == .done ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.subheadline.weight(.medium))
            .symbolRenderingMode(.multicolor)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
    }
}
