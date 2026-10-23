import PDProtocol
import SwiftUI
import UIKit

enum AppInfo {
    static let repository = URL(string: "https://github.com/DamilolaDami/pocketdesk")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }

    /// The hardware model, like `iPhone15,2`: says which device without saying whose.
    static var model: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// A new GitHub issue with the versions filled in. Nothing personal: no names, no Macs.
    static var reportProblemURL: URL {
        var components = URLComponents(url: repository.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
        let body = """
        **What happened**


        **What you expected**


        **Steps to reproduce**
        1.

        ---
        PocketDesk \(version) (\(build)) · protocol \(protocolVersion)
        iOS \(UIDevice.current.systemVersion) · \(model)
        """
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        return components.url!
    }
}

/// What PocketDesk does with your data: very little, and all of it on your devices.
struct PrivacyView: View {
    private let points: [(symbol: String, color: Color, title: String, text: String)] = [
        ("person.crop.circle.badge.xmark", .gray, "No Account, No Servers",
         "PocketDesk has no sign-in and no servers of its own. Your iPhone talks straight to your Mac over your network."),
        ("chart.bar.xaxis", .orange, "No Tracking",
         "No analytics, no advertising, no crash reporting. Nothing about how you use PocketDesk leaves your devices."),
        ("lock.shield.fill", .green, "Encrypted End to End",
         "Every connection uses TLS 1.3, and each side only accepts the exact key it pinned when you paired. Not even someone on the same Wi-Fi can watch or join."),
        ("internaldrive.fill", .blue, "Stored on Your iPhone",
         "Paired Macs, their keys (in the Keychain), your shortcuts, settings and each Mac's desktop picture stay on this iPhone. Forgetting a Mac removes what PocketDesk kept about it."),
        ("doc.on.clipboard.fill", .indigo, "Clipboard and Files",
         "What you copy is shared with the Mac only while Share Clipboard is on, and only during a session. Photos and files you send go to that Mac and nowhere else."),
        ("faceid", .pink, "Face ID",
         "iOS checks your face or passcode. PocketDesk only learns whether it was you, never anything about your face."),
        ("camera.fill", .purple, "Camera and Local Network",
         "The camera is used only to scan a pairing code. Local network access is how your iPhone finds your Macs."),
    ]

    var body: some View {
        Form {
            Section {
                Text("PocketDesk is built so your Mac and what's on it stay between your Mac and your iPhone.")
                    .font(.body)
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(points, id: \.title) { point in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: point.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(point.color.gradient, in: .rect(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(point.title).font(.headline)
                            Text(point.text).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("PocketDesk is open source, so all of this can be checked in its code.")
            }
        }
        .scrollContentBackground(.hidden)
        .background { AppBackground() }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// PocketDesk's licence and the open-source code it's built on.
struct LicensesView: View {
    private struct Component: Identifiable {
        let name: String
        let by: String
        let license: String
        let url: String
        var id: String { name }
    }

    private let components = [
        Component(name: "swift-certificates", by: "Apple", license: "Apache License 2.0", url: "https://github.com/apple/swift-certificates"),
        Component(name: "swift-crypto", by: "Apple", license: "Apache License 2.0", url: "https://github.com/apple/swift-crypto"),
        Component(name: "swift-asn1", by: "Apple", license: "Apache License 2.0", url: "https://github.com/apple/swift-asn1"),
    ]

    var body: some View {
        Form {
            Section {
                Link(destination: AppInfo.repository.appendingPathComponent("blob/main/LICENSE")) {
                    row("PocketDesk", by: "PocketDesk contributors", license: "Apache License 2.0")
                }
            } header: {
                Text("This App")
            } footer: {
                Text("Free to use, change and share under the Apache License 2.0.")
            }
            Section("Built With") {
                ForEach(components) { component in
                    Link(destination: URL(string: component.url)!) {
                        row(component.name, by: component.by, license: component.license)
                    }
                }
            }
        }
        .foregroundStyle(.primary)
        .scrollContentBackground(.hidden)
        .background { AppBackground() }
        .navigationTitle("Licences")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ name: String, by: String, license: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text("\(by) · \(license)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }
}
