#if os(macOS)
import AppKit
import Foundation
import Observation
import PDProtocol
import Sparkle

public protocol HostUpdating: Sendable {
    func status() async -> HostUpdateStatus
    func install() async -> HostUpdateStatus
}

/// One updater owns all Sparkle activity. The phone can only request the bundled feed.
@MainActor @Observable public final class HostUpdater: NSObject, HostUpdating, SPUUpdaterDelegate {
    public private(set) var state: HostUpdateStatus
    public var beforeRelaunch: (@MainActor () async -> Void)?
    @ObservationIgnored private var updater: SPUUpdater!
    @ObservationIgnored private var driver: HostUpdateDriver!
    @ObservationIgnored private var lastRemoteRequest: ContinuousClock.Instant?

    public override init() {
        state = .init(phase: .idle, version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                      build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        super.init()
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            state.phase = .unavailable; state.message = "This Mac build isn't configured for signed updates."; return
        }
        driver = HostUpdateDriver { [weak self] phase, message, progress in
            self?.state.phase = phase; self?.state.message = message; self?.state.progress = progress
        }
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do { try updater.start() }
        catch { state.phase = .unavailable; state.message = error.localizedDescription }
    }

    public func status() async -> HostUpdateStatus { state }
    public func install() async -> HostUpdateStatus {
        guard updater != nil, state.phase != .unavailable else { return state }
        guard !state.isBusy else { return state }
        guard updater.canCheckForUpdates else {
            var busy = state; busy.phase = .failed
            busy.message = "An update check is already open on the Mac. Finish it there, then try again."
            return busy
        }
        if let lastRemoteRequest, ContinuousClock.now - lastRemoteRequest < .seconds(30) { return state }
        lastRemoteRequest = .now
        driver.remote = true
        state.phase = .checking; state.message = nil; state.progress = nil
        updater.checkForUpdates()
        return state
    }
    public func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates, !state.isBusy else { return }
        driver.remote = false
        state.phase = .checking; state.message = nil; state.progress = nil
        updater.checkForUpdates()
    }
    public var canCheck: Bool { updater?.canCheckForUpdates == true && !state.isBusy }
    public var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }
    public func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                        untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        state.phase = .installing
        Task { await beforeRelaunch?(); installHandler() }
        return true
    }
    public func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if state.phase == .checking { state.phase = error == nil ? .idle : .failed; state.message = error?.localizedDescription }
        driver.remote = false
    }
}

/// Local checks retain Sparkle's standard UI. An explicit phone Install request authorizes
/// download/install/relaunch; OS authorization requirements still belong to macOS.
@MainActor private final class HostUpdateDriver: NSObject, SPUUserDriver {
    var remote = false
    private let standard = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
    private let changed: (HostUpdateStatus.Phase, String?, Double?) -> Void
    private var expected: UInt64 = 0
    private var received: UInt64 = 0
    init(changed: @escaping (HostUpdateStatus.Phase, String?, Double?) -> Void) { self.changed = changed }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard.show(request, reply: reply)
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        changed(.checking, nil, nil)
        if !remote { standard.showUserInitiatedUpdateCheck(cancellation: cancellation) }
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if remote {
            guard !appcastItem.isInformationOnlyUpdate, !appcastItem.isMajorUpgrade else {
                changed(.failed, "This update needs attention on the Mac. Choose Check for Updates in its PocketDesk menu.", nil)
                reply(.dismiss); return
            }
            changed(.downloading, nil, 0); reply(.install)
        } else { standard.showUpdateFound(with: appcastItem, state: state, reply: reply) }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { if !remote { standard.showUpdateReleaseNotes(with: downloadData) } }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) { if !remote { standard.showUpdateReleaseNotesFailedToDownloadWithError(error) } }
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        changed(.upToDate, "The Mac has the latest published update. If versions still differ, update the iPhone app or wait for the matching Mac release.", nil)
        if remote { acknowledgement() } else { standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement) }
    }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        changed(.failed, error.localizedDescription, nil)
        if remote { acknowledgement() } else { standard.showUpdaterError(error, acknowledgement: acknowledgement) }
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expected = 0; received = 0; changed(.downloading, nil, 0)
        if !remote { standard.showDownloadInitiated(cancellation: cancellation) }
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
        if !remote { standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength) }
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received &+= length
        changed(.downloading, nil, expected > 0 ? min(1, Double(received) / Double(expected)) : nil)
        if !remote { standard.showDownloadDidReceiveData(ofLength: length) }
    }
    func showDownloadDidStartExtractingUpdate() {
        changed(.downloading, "Preparing update…", nil)
        if !remote { standard.showDownloadDidStartExtractingUpdate() }
    }
    func showExtractionReceivedProgress(_ progress: Double) { if !remote { standard.showExtractionReceivedProgress(progress) } }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if remote { changed(.installing, "Restarting PocketDesk on the Mac…", nil); reply(.install) }
        else { standard.showReady(toInstallAndRelaunch: reply) }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        changed(.installing, "Installing update…", nil)
        standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        if remote { acknowledgement() } else { standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement) }
    }
    func dismissUpdateInstallation() { standard.dismissUpdateInstallation() }
    func showUpdateInFocus() { if !remote { standard.showUpdateInFocus() } }
}
#endif
