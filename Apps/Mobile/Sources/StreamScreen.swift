import PDClientCore
import PDProtocol
import SwiftUI

/// The Mac, full screen, with a small control bar.
struct StreamScreen: View {
    let controller: SessionController
    let config: StreamConfig
    @State private var keyboardShown = false
    @State private var showingWindows = false

    var body: some View {
        StreamView(controller: controller, videoSize: CGSize(width: config.width, height: config.height),
                   keyboardShown: $keyboardShown)
            .ignoresSafeArea()
            .background(.black)
            .overlay(alignment: .bottom) {
                HStack(spacing: 4) {
                    Button("Keyboard", systemImage: keyboardShown ? "keyboard.chevron.compact.down" : "keyboard") {
                        keyboardShown.toggle()
                    }
                    Button("Windows", systemImage: "macwindow.on.rectangle") {
                        controller.refreshWindows()
                        showingWindows = true
                    }
                    Button("Disconnect", systemImage: "xmark") { controller.disconnect() }
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .buttonStyle(.glass)
                .padding(.bottom, 8)
            }
            .persistentSystemOverlays(.hidden)
            .statusBarHidden()
            .sheet(isPresented: $showingWindows) {
                WindowPicker(controller: controller) { showingWindows = false }
                    .presentationDetents([.medium, .large])
            }
    }
}

/// Stream the whole display or one window (fitted to the phone).
struct WindowPicker: View {
    let controller: SessionController
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Button {
                    controller.selectSource(nil)
                    dismiss()
                } label: {
                    Label("Whole Screen", systemImage: "display")
                }
                Section("Windows") {
                    ForEach(controller.store.windows) { window in
                        Button {
                            controller.selectSource(window)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(window.title.isEmpty ? window.appName : window.title)
                                Text(window.appName).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .overlay {
                if controller.store.windows.isEmpty { ProgressView() }
            }
            .navigationTitle("Show on Phone")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
