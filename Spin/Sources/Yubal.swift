import Foundation

/// yubal on the home server: turns a YouTube Music link into tagged files in the Jellyfin Music folder.
/// It has no login of its own; it is only reachable over the tailnet.
struct Yubal {
    static let defaultServer = "https://haruserver.tail6da04d.ts.net:8930"
    var server = defaultServer

    struct Job: Identifiable, Decodable, Equatable {
        let id: String
        let url: String
        let status: String
        let progress: Double
        let contentInfo: Info?

        struct Info: Decodable, Equatable {
            let title: String
            let artist: String
            let thumbnailUrl: String?
            let trackCount: Int?
        }

        var finished: Bool { ["completed", "failed", "cancelled"].contains(status) }
        var label: String {
            switch status {
            case "pending": return "Queued"
            case "fetching_info": return "Reading"
            case "downloading": return "Downloading"
            case "importing": return "Tagging"
            case "completed": return "In library"
            case "failed": return "Failed"
            case "cancelled": return "Cancelled"
            default: return status
            }
        }
    }

    /// A link shared from YouTube Music or YouTube; anything else is refused before it is sent.
    static func isLink(_ text: String) -> Bool {
        guard let host = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    func add(_ link: String) async throws {
        var request = URLRequest(url: URL(string: server + "/api/jobs")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["url": link.trimmingCharacters(in: .whitespacesAndNewlines)])
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 201 else { throw YubalError(code: code, body: data) }
    }

    /// Clears finished downloads from yubal's list; running ones stay.
    func clear() async throws {
        var request = URLRequest(url: URL(string: server + "/api/jobs")!)
        request.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: request)
    }

    func jobs() async throws -> [Job] {
        let (data, response) = try await URLSession.shared.data(from: URL(string: server + "/api/jobs")!)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw YubalError(code: code, body: data) }
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> [Job] {
        struct Page: Decodable { let jobs: [Job] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Page.self, from: data).jobs.reversed()  // newest first
    }
}

struct YubalError: LocalizedError {
    let code: Int
    let body: Data
    /// SoundCloud's duplicate check: the song is already in the library.
    var duplicate: Bool { code == 409 && (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["duplicate"] as? Bool == true }
    var errorDescription: String? {
        if code == 409 && !duplicate { return "The download queue is full. Try again in a moment." }
        // FastAPI puts the reason in "detail": a string, or a list of {msg} for a bad link.
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let detail = json["detail"] as? String { return detail }
            if let msg = (json["detail"] as? [[String: Any]])?.first?["msg"] as? String { return msg }
        }
        return code == 0 ? "The downloader is not reachable. Is Tailscale on?" : "The downloader answered \(code)."
    }
}

/// spin-sources on the home server: YouTube Music and SoundCloud search (ytmusicapi, SoundCloud's API) and
/// SoundCloud downloads (scdl). Its queue has yubal's job shape. Mounted at /sources beside yubal.
struct Sources {
    static let defaultServer = Yubal.defaultServer + "/sources"
    var server = defaultServer

    enum Source: String, CaseIterable, Identifiable {
        case youtube, soundcloud
        var id: String { rawValue }
        var title: String { self == .youtube ? "YouTube Music" : "SoundCloud" }
    }

    struct Result: Identifiable, Decodable, Equatable {
        let kind: String
        let title: String
        let artist: String
        let detail: String
        let duration: String
        let thumbnail: String?
        let url: String
        var id: String { url }
    }

    static func isSoundCloud(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "soundcloud.com" || host.hasSuffix(".soundcloud.com")
    }

    func search(_ query: String, in source: Source) async throws -> [Result] {
        var parts = URLComponents(string: server + "/search")!
        parts.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "source", value: source.rawValue)]
        let (data, response) = try await URLSession.shared.data(from: parts.url!)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw YubalError(code: code, body: data) }
        return try Self.decodeResults(data)
    }

    /// Queues a SoundCloud link; `force` downloads it even when it is already in the library.
    func add(_ link: String, force: Bool = false) async throws {
        struct Body: Encodable { let url: String; let force: Bool }
        _ = try await send("POST", "/soundcloud", body: try JSONEncoder().encode(Body(url: link.trimmingCharacters(in: .whitespacesAndNewlines), force: force)), expect: 201)
    }

    func clearSoundCloud() async throws { _ = try await send("DELETE", "/soundcloud") }

    // Library changes act on the files themselves; the server checks the Jellyfin sign-in is an administrator's.

    func refreshLibrary(_ client: Jellyfin) async throws { _ = try await send("POST", "/library/refresh", client: client) }

    func edit(_ track: Track, title: String, artist: String, album: String, via client: Jellyfin) async throws {
        let body = try JSONEncoder().encode(["title": title, "artist": artist, "album": album])
        _ = try await send("PATCH", "/library/items/\(track.id)", body: body, client: client)
    }

    func setArt(_ track: Track, jpeg: Data, via client: Jellyfin) async throws {
        _ = try await send("PUT", "/library/items/\(track.id)/art", body: jpeg, type: "image/jpeg", client: client)
    }

    func delete(_ track: Track, via client: Jellyfin) async throws {
        _ = try await send("DELETE", "/library/items/\(track.id)", client: client)
    }

    private func send(_ method: String, _ path: String, body: Data? = nil, type: String = "application/json",
                      client: Jellyfin? = nil, expect: Int = 200) async throws -> Data {
        var request = URLRequest(url: URL(string: server + path)!)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 60
        if body != nil { request.setValue(type, forHTTPHeaderField: "Content-Type") }
        if let client { request.setValue(Jellyfin.authorization(token: client.token), forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == expect else { throw YubalError(code: code, body: data) }
        return data
    }

    func jobs() async throws -> [Yubal.Job] {
        let (data, response) = try await URLSession.shared.data(from: URL(string: server + "/soundcloud")!)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw YubalError(code: code, body: data) }
        return try Yubal.decode(data)
    }

    /// Whether a search result looks like a song already in the library: same title, and its first artist among the song's.
    static func inLibrary(_ result: Result, _ songs: [Track]) -> Bool {
        guard result.kind == "song" || result.kind == "track" else { return false }
        let title = plain(result.title)
        let artist = plain(String(result.artist.split(separator: ",").first ?? ""))
        return songs.contains { plain($0.name) == title && plain($0.artist).contains(artist) }
    }

    /// Lowercase letters and digits only, so punctuation and spacing don't hide a match.
    static func plain(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func decodeResults(_ data: Data) throws -> [Result] {
        struct Page: Decodable { let results: [Result] }
        return try JSONDecoder().decode(Page.self, from: data).results
    }
}
