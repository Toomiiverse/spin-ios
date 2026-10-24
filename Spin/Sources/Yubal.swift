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
    var errorDescription: String? {
        if code == 409 { return "The download queue is full. Try again in a moment." }
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

    func add(_ link: String) async throws {
        var request = URLRequest(url: URL(string: server + "/soundcloud")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["url": link.trimmingCharacters(in: .whitespacesAndNewlines)])
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 201 else { throw YubalError(code: code, body: data) }
    }

    func jobs() async throws -> [Yubal.Job] {
        let (data, response) = try await URLSession.shared.data(from: URL(string: server + "/soundcloud")!)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw YubalError(code: code, body: data) }
        return try Yubal.decode(data)
    }

    static func decodeResults(_ data: Data) throws -> [Result] {
        struct Page: Decodable { let results: [Result] }
        return try JSONDecoder().decode(Page.self, from: data).results
    }
}
