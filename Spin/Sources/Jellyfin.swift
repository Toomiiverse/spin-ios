import Foundation
import Combine

struct Track: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let album: String?
    let albumId: String?
    let artists: [String]?
    let runTimeTicks: Int64?
    let imageTags: [String: String]?
    let albumPrimaryImageTag: String?
    /// Set only on songs read from a playlist: which entry this is, so the same song can sit there twice.
    var playlistItemId: String? = nil

    var artist: String { (artists ?? []).joined(separator: ", ") }
    /// Whose picture to show: the album's when there is one, else the song's own embedded art.
    var artId: String { albumId ?? id }
    /// Changes when the picture does, so a new cover replaces the cached one.
    var artTag: String? { albumId != nil ? albumPrimaryImageTag : imageTags?["Primary"] }
    var seconds: Double { Double(runTimeTicks ?? 0) / 10_000_000 }
}

/// The same song picked twice goes in once.
func unique(_ songs: [Track]) -> [Track] {
    var seen = Set<String>()
    return songs.filter { seen.insert($0.id).inserted }
}

func songCount(_ songs: Int) -> String { songs == 1 ? "1 song" : "\(songs) songs" }

struct Playlist: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let childCount: Int?
    /// Jellyfin draws a collage of the first covers once a playlist has songs.
    let imageTags: [String: String]?
}

enum JellyfinError: LocalizedError {
    case badServer, signIn, status(Int)
    var errorDescription: String? {
        switch self {
        case .badServer: return "That server address does not look right."
        case .signIn: return "Jellyfin did not accept that name and password."
        case .status(let code): return "Jellyfin answered \(code)."
        }
    }
}

/// A signed-in Jellyfin user on one server: plain URLSession calls, PascalCase JSON decoded into the models above.
struct Jellyfin {
    let server: String
    let token: String
    let userId: String

    /// One id per install, so Jellyfin lists this phone once under Devices.
    static let deviceId: String = {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "deviceId") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "deviceId")
        return id
    }()

    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.contains("://") { s = "https://" + s }
        return s
    }

    static func authenticate(server raw: String, username: String, password: String) async throws -> Jellyfin {
        let server = normalize(raw)
        guard let url = URL(string: server + "/Users/AuthenticateByName"), url.host != nil else { throw JellyfinError.badServer }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization(token: nil), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw JellyfinError.signIn }
        struct Auth: Decodable { let accessToken: String; let user: User; struct User: Decodable { let id: String } }
        let auth = try decoder.decode(Auth.self, from: data)
        return Jellyfin(server: server, token: auth.accessToken, userId: auth.user.id)
    }

    /// Every song, newest first, so whatever was just added sits on top.
    /// shortcut: one request for the whole library, fine for a personal collection; page it past a few thousand songs.
    func songs() async throws -> [Track] {
        try await items("includeItemTypes=Audio&recursive=true&sortBy=DateCreated,SortName&sortOrder=Descending")
    }

    func playlists() async throws -> [Playlist] {
        try await items("includeItemTypes=Playlist&recursive=true&sortBy=SortName&fields=ChildCount")
    }

    func songs(in playlist: Playlist) async throws -> [Track] {
        try Self.decode(try await send("GET", "/Playlists/\(playlist.id)/Items?userId=\(userId)"))
    }

    func createPlaylist(_ name: String, songs: [Track]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["Name": name, "Ids": songs.map(\.id), "UserId": userId, "MediaType": "Audio"])
        _ = try await send("POST", "/Playlists", body: body)
    }

    func add(_ songs: [Track], to playlist: Playlist) async throws {
        _ = try await send("POST", "/Playlists/\(playlist.id)/Items?userId=\(userId)&ids=\(songs.map(\.id).joined(separator: ","))")
    }

    func remove(_ entries: [Track], from playlist: Playlist) async throws {
        _ = try await send("DELETE", "/Playlists/\(playlist.id)/Items?entryIds=\(entries.compactMap(\.playlistItemId).joined(separator: ","))")
    }

    /// Only the playlist goes; its songs stay in the library.
    func delete(_ playlist: Playlist) async throws {
        _ = try await send("DELETE", "/Items/\(playlist.id)")
    }

    /// Album art, square. Jellyfin answers 404 for an album without one; the views show a blank disc then.
    func artwork(_ itemId: String, size: Int = 600, tag: String? = nil) -> URL? {
        URL(string: "\(server)/Items/\(itemId)/Images/Primary?fillWidth=\(size)&fillHeight=\(size)&quality=90" + (tag.map { "&tag=\($0)" } ?? ""))
    }

    func artwork(for track: Track, size: Int = 600) -> URL? { artwork(track.artId, size: size, tag: track.artTag) }

    /// Direct play when the phone can decode the file, else Jellyfin transcodes to AAC over HLS.
    /// The token travels in the query because AVPlayer sends no headers of ours.
    func stream(_ track: Track) -> URL? {
        URL(string: "\(server)/Audio/\(track.id)/universal?userId=\(userId)&deviceId=\(Self.deviceId)&api_key=\(token)"
            + "&container=mp3,aac,m4a%7Caac,m4b%7Caac,flac,alac,m4a%7Calac,wav,aiff"
            + "&transcodingContainer=ts&transcodingProtocol=hls&audioCodec=aac&maxStreamingBitrate=100000000")
    }

    /// The original file, as stored on the server.
    func download(_ track: Track) -> URL? { URL(string: "\(server)/Items/\(track.id)/Download?api_key=\(token)") }

    static func authorization(token: String?) -> String {
        var header = "MediaBrowser Client=\"Spin\", Device=\"iPhone\", DeviceId=\"\(deviceId)\", Version=\"1.0\""
        if let token { header += ", Token=\"\(token)\"" }
        return header
    }

    static func decode<T: Decodable>(_ data: Data) throws -> [T] {
        try decoder.decode(Page<T>.self, from: data).items
    }

    private func items<T: Decodable>(_ query: String) async throws -> [T] {
        try Self.decode(try await send("GET", "/Items?userId=\(userId)&\(query)"))
    }

    private func send(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: server + path) else { throw JellyfinError.badServer }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue(Self.authorization(token: token), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw JellyfinError.status(code) }
        return data
    }

    /// Jellyfin's "Name" becomes the models' "name", and so on.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { keys in
            let key = keys.last!.stringValue
            return CamelKey(key.prefix(1).lowercased() + String(key.dropFirst()))
        }
        return decoder
    }()
}

private struct Page<T: Decodable>: Decodable { let items: [T] }

private struct CamelKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Who is signed in, remembered across launches.
@MainActor final class Session: ObservableObject {
    static let defaultServer = "https://haruserver.tail6da04d.ts.net:8920"
    @Published private(set) var client: Jellyfin?

    init() {
        let defaults = UserDefaults.standard
        if let server = defaults.string(forKey: "server"), let token = defaults.string(forKey: "token"),
           let userId = defaults.string(forKey: "userId") {
            client = Jellyfin(server: server, token: token, userId: userId)
        }
    }

    func signIn(server: String, username: String, password: String) async throws {
        let signedIn = try await Jellyfin.authenticate(server: server, username: username, password: password)
        let defaults = UserDefaults.standard
        defaults.set(signedIn.server, forKey: "server")
        defaults.set(signedIn.token, forKey: "token")
        defaults.set(signedIn.userId, forKey: "userId")
        client = signedIn
    }

    func signOut() {
        for key in ["server", "token", "userId"] { UserDefaults.standard.removeObject(forKey: key) }
        client = nil
    }
}
