import PDClientCore
import SwiftUI

struct DisplayPicker: View {
    let controller: SessionController
    let dismiss: () -> Void

    private var showingWholeDisplay: Bool {
        if case .streaming(_, _, nil) = controller.store.state { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(controller.store.displaySelection.displays.enumerated()), id: \.element.id) { index, display in
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
                } footer: {
                    Text("PocketDesk remembers the display you choose for this Mac.")
                }
            }
            .overlay {
                if controller.store.displaySelection.displays.isEmpty {
                    ContentUnavailableView("No Displays Available", systemImage: "display.trianglebadge.exclamationmark",
                                           description: Text("Connect a display to your Mac and try again."))
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
        }
    }
}
