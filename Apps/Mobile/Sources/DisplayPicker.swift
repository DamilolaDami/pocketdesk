import PDClientCore
import PDProtocol
import SwiftUI

struct DisplayPicker: View {
    let controller: SessionController
    let dismiss: () -> Void
    @State private var confirmingEnd = false

    private var virtual: VirtualDisplaySelection { controller.store.virtualDisplay }
    private var workspace: VirtualDisplayReport.Workspace? { virtual.report?.workspace }

    private var showingWholeDisplay: Bool {
        if case .streaming(_, _, nil) = controller.store.state { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            List {
                virtualWorkspaceSection
                Section {
                    ForEach(Array(controller.store.displaySelection.displays.filter { $0.id != workspace?.displayID }.enumerated()), id: \.element.id) { index, display in
                        Button {
                            controller.selectDisplay(display)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "display").font(.title2).foregroundStyle(Brand.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(display.name) · \(index + 1)").font(.body.weight(.medium))
                                    Text("\(display.width) × \(display.height)\(display.isMain ? " · Main display" : "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if showingWholeDisplay && controller.store.displaySelection.selectedID == display.id {
                                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Brand.accent)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Mac displays")
                } footer: {
                    Text("PocketDesk remembers the display you choose for this Mac.")
                }
            }
            .navigationTitle("Displays")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: dismiss)
                }
            }
            .task { controller.refreshDisplays() }
            .refreshable { controller.refreshDisplays() }
            .confirmationDialog("End virtual workspace?", isPresented: $confirmingEnd, titleVisibility: .visible) {
                Button("End Workspace", role: .destructive) { controller.endVirtualDisplay() }
            } message: {
                Text("The extra display will be removed and PocketDesk will return to the Mac's main display. Open windows may move to a remaining Mac display.")
            }
        }
    }

    @ViewBuilder private var virtualWorkspaceSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "display.badge.plus")
                    .font(.title2).foregroundStyle(Brand.accent)
                    .frame(width: 48, height: 48)
                    .background(Brand.accent.opacity(0.1), in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Virtual workspace").font(.headline)
                    Text(workspace == nil ? "An extra desktop for this device." : (workspace?.isOwner == true ? "Your own space on the Mac." : "Currently in use on another device."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if workspace?.isOwner == true {
                    Text("Active").font(.caption.weight(.medium))
                        .foregroundStyle(Brand.accent)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Brand.accent.opacity(0.1), in: .capsule)
                }
            }
            .padding(.vertical, 6)
            if virtual.isBusy {
                HStack {
                    ProgressView()
                    Text(virtual.report?.phase == .ending ? "Ending workspace…" : (virtual.report?.phase == .configuring ? "Resizing workspace…" : "Waiting for your Mac…"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if let workspace, workspace.isOwner {
                let mode = workspace.acceptedMode
                workspaceSettings(mode: mode)
                if let display = controller.store.displaySelection.displays.first(where: { $0.id == workspace.displayID }) {
                    Button {
                        controller.selectDisplay(display)
                        dismiss()
                    } label: {
                        HStack {
                            Text("Show Virtual Display")
                            Spacer()
                            if showingWholeDisplay && controller.store.displaySelection.selectedID == workspace.displayID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(virtual.isBusy || virtual.report?.phase != .active)
                }
                if let physical = controller.store.displaySelection.displays.first(where: { $0.isMain && $0.id != workspace.displayID }) {
                    Button("Return to Mac Display") { controller.selectDisplay(physical); dismiss() }
                        .disabled(virtual.report?.phase == .ending)
                }
                Button(virtual.report?.phase == .cleanupFailed ? "Retry End Workspace" : "End Workspace", role: .destructive) {
                    confirmingEnd = true
                }
                .disabled(virtual.isBusy)
            } else if let workspace {
                Text("A workspace is in use by \(workspace.ownerName). End it on the Mac or from its viewing device before creating another.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if virtual.report?.canCreate == true {
                workspaceSettings(mode: controller.store.workspaceSizing.mode)
                Button { controller.createVirtualDisplay() } label: {
                    Label("Add Workspace", systemImage: "plus")
                        .font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Brand.accent)
                .listRowSeparator(.hidden)
                .disabled(virtual.isBusy)
            } else if virtual.report == nil {
                Text("Checking Mac support…").font(.subheadline).foregroundStyle(.secondary)
                Button("Refresh") { controller.refreshDisplays() }
            }
            if let message = virtual.problem ?? virtual.report?.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            Text("Your Mac screens stay on. The workspace closes when you end it or disconnect.")
        }
    }

    private func workspaceSettings(mode: VirtualDisplayMode) -> some View {
        NavigationLink {
            WorkspaceSizingControls(controller: controller)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Workspace settings").font(.subheadline.weight(.medium))
                    Text("\(mode.width) × \(mode.height)  ·  \(mode.scale == 2 ? "Retina" : "Standard")  ·  \(mode.refreshRate) fps")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
            }
            .padding(.vertical, 3)
        }
        .disabled(virtual.isBusy)
    }

}
