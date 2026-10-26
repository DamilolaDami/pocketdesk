#if os(macOS)
import AppKit
import PDProtocol

/// Which website a browser is playing from, so the phone can show its icon (Netflix's N, not
/// Safari's compass). macOS only says the browser, so this asks the browser for its tabs and
/// picks the one whose title has what's playing in it. Asked once per song: status goes out
/// every second. The first time, macOS asks the person at the Mac to let PocketDesk see the
/// browser; until they do (or if they don't) there's simply no site.
actor PlayingSite {
    static let shared = PlayingSite()

    /// Browsers that answer Apple Events about their tabs, and what their tabs call the title.
    static let browsers: [String: String] = [
        "com.apple.Safari": "name",
        "com.apple.SafariTechnologyPreview": "name",
        "com.google.Chrome": "title",
        "com.brave.Browser": "title",
        "com.microsoft.edgemac": "title",
        "com.vivaldi.Vivaldi": "title",
        "company.thebrowser.Browser": "title",
    ]

    private var last: (key: String, found: Found?, at: ContinuousClock.Instant)?

    /// The site, and the browser it's in.
    struct Found: Equatable {
        var site: String
        var browser: String
    }

    /// Asks the browser macOS named, or, when it named none (a site's sound comes from a
    /// WebKit process outside the browser's bundle, so often it can't), every browser
    /// that's open.
    func site(for playing: NowPlaying) async -> Found? {
        let candidates = playing.app.map { [$0.bundleID] } ?? Self.browsers.keys.sorted()
        let browsers = candidates.filter { Self.browsers[$0] != nil }
        guard !browsers.isEmpty else { return nil }
        let key = "\(browsers.joined(separator: ","))\n\(playing.title)"
        // No answer is asked again now and then: the Mac may have been showing its permission prompt.
        if let last, last.key == key, last.found != nil || .now - last.at < .seconds(30) { return last.found }
        var found: Found?
        for browser in browsers {
            guard let titleKey = Self.browsers[browser], let tabs = await Self.tabs(of: browser, titleKey: titleKey),
                  let site = Self.match(playing.title, in: tabs) else { continue }
            found = Found(site: site, browser: browser)
            break
        }
        last = (key, found, .now)
        return found
    }

    /// Every open tab's title and address. `nil` when the browser won't say.
    static func tabs(of bundleID: String, titleKey: String) async -> [(title: String, url: String)]? {
        // Never start a browser that isn't open (asking would launch it).
        let running = await MainActor.run {
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }
        guard running else { return nil }
        let script = """
            const app = Application("\(bundleID)");
            JSON.stringify(app.windows().flatMap(w => w.tabs().map(t => [t.\(titleKey)() || "", t.url() || ""])));
            """
        guard let result = try? await Subprocess.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", script],
                                                     timeout: .seconds(4)),
              result.status == 0,
              let pairs = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String]] else { return nil }
        return pairs.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }

    /// The host of the tab playing `title`: its tab title holds the song or show's title
    /// ("Stranger Things | Netflix", "Song - YouTube"). Web addresses only.
    static func match(_ title: String, in tabs: [(title: String, url: String)]) -> String? {
        let wanted = title.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        let web = tabs.compactMap { tab -> (title: String, host: String)? in
            guard let url = URL(string: tab.url), ["http", "https"].contains(url.scheme), let host = url.host() else { return nil }
            return (tab.title, host)
        }
        return web.first { $0.title.localizedCaseInsensitiveContains(wanted) }?.host
            ?? web.first { !$0.title.isEmpty && wanted.localizedCaseInsensitiveContains($0.title) }?.host
    }
}
#endif
