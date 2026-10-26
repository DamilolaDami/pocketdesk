import Foundation
import Testing
@testable import PDClientCore
import PDProtocol

@MainActor
struct NowPlayingControlTests {
    private func controller(in directory: URL) -> SessionController {
        let c = SessionController(trustStoreURL: directory.appending(path: "trust.json"),
                                  shortcutsURL: directory.appending(path: "shortcuts.json"),
                                  cacheDirectory: directory,
                                  displayPreferencesURL: directory.appending(path: "display.json"),
                                  wakeBookURL: directory.appending(path: "wake.json"),
                                  macKindsURL: directory.appending(path: "kinds.json"),
                                  macNamesURL: directory.appending(path: "names.json"),
                                  lastUsedURL: directory.appending(path: "used.json"),
                                  locksURL: directory.appending(path: "locks.json"))
        c.controlDiagnostics = NowPlayingControlDiagnostics(url: directory.appending(path: "control.json"))
        return c
    }

    @Test func coldIntentWaitsForAdoptionAndPinsTheCorrectMac() async throws {
        let directory = URL.temporaryDirectory.appending(path: "control-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = controller(in: directory)
        let presenter = ControlPresenter(delayAdoption: true)
        controller.nowPlayingPresenter = presenter
        var delivered: [UUID] = []
        let task = Task { @MainActor in
            await controller.performNowPlayingControl(.next) { shortcut, hostID in
                #expect(shortcut.action == .media(.next))
                #expect(shortcut.macID == hostID)
                delivered.append(hostID)
            }
        }
        await presenter.waitForAdoption()
        #expect(delivered.isEmpty)
        await presenter.releaseAdoption()
        #expect(await task.value)
        #expect(delivered == [presenter.hostID])
    }

    @Test func aFailedButtonRestoresItsOriginalCard() async throws {
        let directory = URL.temporaryDirectory.appending(path: "control-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = controller(in: directory)
        let presenter = ControlPresenter()
        controller.nowPlayingPresenter = presenter
        let sent = await controller.performNowPlayingControl(.playPause) { (_, _) async throws(SessionController.BackgroundRunError) -> Void in
            throw .failed("offline")
        }
        #expect(!sent)
        await presenter.waitForRestoration()
        let data = try Data(contentsOf: directory.appending(path: "control.json"))
        let diagnostic = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(diagnostic["stage"] as? String == "failed")
        #expect(!String(decoding: data, as: UTF8.self).contains(presenter.card.title))
    }

    @Test func missingActivityDoesNotControlAnArbitraryPairedMac() async {
        let directory = URL.temporaryDirectory.appending(path: "control-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = controller(in: directory)
        var ran = false
        #expect(await !controller.performNowPlayingControl(.next) { _, _ in ran = true })
        #expect(!ran)
    }
}

private actor ControlPresenter: NowPlayingPresenter {
    nonisolated let hostID = UUID()
    nonisolated let card = NowPlayingCard(title: "Private song", macName: "Studio", isPlaying: true)
    private let delayAdoption: Bool
    private var adoption: CheckedContinuation<Void, Never>?
    private var adoptionWaiter: CheckedContinuation<Void, Never>?
    private var restoration: CheckedContinuation<Void, Never>?
    private var restored = false
    init(delayAdoption: Bool = false) { self.delayAdoption = delayAdoption }
    func adopt() async -> (hostID: UUID, card: NowPlayingCard)? {
        if delayAdoption {
            await withCheckedContinuation { adoption = $0; adoptionWaiter?.resume(); adoptionWaiter = nil }
        }
        return (hostID, card)
    }
    func waitForAdoption() async {
        if adoption != nil { return }
        await withCheckedContinuation { adoptionWaiter = $0 }
    }
    func releaseAdoption() { adoption?.resume(); adoption = nil }
    func apply(_ step: NowPlayingActivityStep, images: [String: Data]) {
        if step == .update(card) { restored = true; restoration?.resume(); restoration = nil }
    }
    func waitForRestoration() async {
        if restored { return }
        await withCheckedContinuation { restoration = $0 }
    }
}
