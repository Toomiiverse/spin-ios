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
