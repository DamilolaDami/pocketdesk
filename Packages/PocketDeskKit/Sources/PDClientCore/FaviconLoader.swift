import Foundation
import ImageIO

/// Icons for website shortcuts, fetched from the site itself (never a third-party favicon
/// service, which would learn every site you've added) and cached on disk.
public actor FaviconLoader {
    public static let shared = FaviconLoader()

    private let cacheDirectory: URL
    private let session: URLSession
    private var memory: [String: Data] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]

    public init(cacheDirectory: URL = URL.cachesDirectory.appending(path: "PocketDesk/favicons"),
                session: URLSession = .shared) {
        self.cacheDirectory = cacheDirectory
        self.session = session
    }

    /// Image data for the site `url` points at, or `nil` if it has no usable icon.
    public func icon(for url: String) async -> Data? {
        guard let site = URL(string: url), let scheme = site.scheme, ["http", "https"].contains(scheme),
              let host = site.host() else { return nil }
        if let data = memory[host] { return data }
        let file = cacheDirectory.appending(path: host)
        if let data = try? Data(contentsOf: file) {
            memory[host] = data
            return data
        }
        if let task = inFlight[host] { return await task.value }

        let task = Task { await fetch(site: URL(string: "https://\(host)/")!) }
        inFlight[host] = task
        let data = await task.value
        inFlight[host] = nil
        if let data {
            memory[host] = data
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return data
    }

    private func fetch(site: URL) async -> Data? {
        var candidates: [URL] = []
        if let (html, response) = try? await session.data(for: Self.request(site)),
           let page = String(data: html.prefix(512 * 1024), encoding: .utf8) ?? String(data: html, encoding: .isoLatin1) {
            candidates = Self.candidates(inHTML: page, baseURL: response.url ?? site)
        }
        candidates += ["/apple-touch-icon.png", "/favicon.ico"].compactMap { URL(string: $0, relativeTo: site)?.absoluteURL }

        for candidate in candidates {
            guard let (data, response) = try? await session.data(for: Self.request(candidate)),
                  (response as? HTTPURLResponse)?.statusCode == 200, Self.isImage(data) else { continue }
            return data
        }
        return nil
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 10)
        // Some sites only advertise touch icons to mobile Safari.
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Icon links in a page, best first: touch icons (big, opaque), then other icons by
    /// declared size. SVG is skipped because ImageIO can't draw it.
    public static func candidates(inHTML html: String, baseURL: URL) -> [URL] {
        struct Icon { var url: URL; var rank: Int; var size: Int }
        var icons: [Icon] = []
        for match in html.matches(of: /(?i)<link\b[^>]*>/) {
            let attributes = Self.attributes(in: String(match.output))
            guard let rel = attributes["rel"]?.lowercased(), let href = attributes["href"],
                  !href.lowercased().hasSuffix(".svg"), attributes["type"]?.contains("svg") != true,
                  let url = URL(string: href.trimmingCharacters(in: .whitespaces), relativeTo: baseURL)?.absoluteURL
            else { continue }
            let rels = rel.split(separator: " ")
            let rank: Int
            if rels.contains("apple-touch-icon") || rels.contains("apple-touch-icon-precomposed") { rank = 0 }
            else if rels.contains("icon") { rank = 1 }
            else { continue }
            let size = attributes["sizes"]?.split(separator: "x").first.flatMap { Int($0) } ?? 0
            icons.append(Icon(url: url, rank: rank, size: size))
        }
        return icons.sorted { ($0.rank, -$0.size) < ($1.rank, -$1.size) }.map(\.url)
    }

    private static func attributes(in tag: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in tag.matches(of: /([a-zA-Z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/) {
            let value = match.output.2 ?? match.output.3 ?? match.output.4 ?? ""
            result[match.output.1.lowercased()] = String(value)
        }
        return result
    }

    static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}
