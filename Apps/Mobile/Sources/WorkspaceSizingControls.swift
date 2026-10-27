import PDClientCore
import PDProtocol
import SwiftUI

/// Dedicated sizing screen keeps the display picker focused on choosing a workspace.
struct WorkspaceSizingControls: View {
    let controller: SessionController
    private var sizing: WorkspaceSizing { controller.store.workspaceSizing }
    private func binding<Value>(_ path: WritableKeyPath<WorkspaceSizing, Value>) -> Binding<Value> {
        Binding(get: { sizing[keyPath: path] }, set: { value in
            var next = sizing
            next[keyPath: path] = value
            controller.setWorkspaceSizing(next)
        })
    }

    var body: some View {
        Form {
            Section {
                ForEach(WorkspaceSizing.Desktop.allCases, id: \.self) { desktop in
                    Button {
                        var next = sizing; next.desktop = desktop
                        controller.setWorkspaceSizing(next)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: desktop == .largerText ? "textformat.size" : (desktop == .tablet ? "rectangle.ratio.4.to.3" : "rectangle.expand.vertical"))
                                .font(.title3).foregroundStyle(Brand.accent).frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(title(desktop)).font(.body.weight(.medium)).foregroundStyle(.primary)
                                Text(detail(desktop)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: sizing.desktop == desktop ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(sizing.desktop == desktop ? Brand.accent : Color.secondary.opacity(0.3))
                        }
                        .padding(.vertical, 5)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(sizing.desktop == desktop ? .isSelected : [])
                }
            } header: { Text("Desktop size") }

            Section {
                Toggle(isOn: Binding(get: { sizing.mode.scale == 2 }, set: {
                    var next = sizing; next.scale = $0 ? 2 : 1; controller.setWorkspaceSizing(next)
                })) {
                    Label("Retina sharpness", systemImage: "sparkles")
                }
                .disabled(sizing.portrait)
                Picker("Frame-rate limit", selection: binding(\.refreshRate)) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
            } header: { Text("Picture") } footer: {
                Text(sizing.portrait ? "Portrait uses Retina. Stream quality still follows your quality preset." : "Retina sharpens text. Your quality preset still controls bandwidth.")
            }

            Section {
                Toggle(isOn: binding(\.followsRotation)) {
                    Label("Follow device rotation", systemImage: "rotate.right")
                }
                if !sizing.followsRotation {
                    Picker("Orientation", selection: binding(\.portrait)) {
                        Text("Landscape").tag(false)
                        Text("Portrait").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            } header: { Text("Orientation") } footer: {
                Text("The keyboard and split view keep your desktop size.")
            }
        }
        .tint(Brand.accent)
        .disabled(controller.store.virtualDisplay.isBusy)
        .navigationTitle("Workspace Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func title(_ desktop: WorkspaceSizing.Desktop) -> String {
        switch desktop {
        case .largerText: "Larger text"
        case .standard: "More space"
        case .tablet: "Tablet"
        }
    }
    private func detail(_ desktop: WorkspaceSizing.Desktop) -> String {
        switch desktop {
        case .largerText: "1024 × 768 · Easier to read"
        case .standard: "1280 × 800 · Room to work"
        case .tablet: "1280 × 960 · Taller canvas"
        }
    }
}
