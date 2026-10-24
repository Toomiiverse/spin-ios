import Foundation
import Combine

struct Album: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let albumArtist: String?
    let productionYear: Int?
}

struct Track: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let album: String?
    let albumId: String?
    let artists: [String]?
    let runTimeTicks: Int64?

    var artist: String { (artists ?? []).joined(separator: ", ") }
    var seconds: Double { Double(runTimeTicks ?? 0) / 10_000_000 }
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

    func albums() async throws -> [Album] {
        try await items("includeItemTypes=MusicAlbum&recursive=true&sortBy=AlbumArtist,SortName&sortOrder=Ascending")
    }

    func tracks(of album: Album) async throws -> [Track] {
        try await items("parentId=\(album.id)&includeItemTypes=Audio&sortBy=ParentIndexNumber,IndexNumber,SortName&sortOrder=Ascending")
    }

    /// Album art, square. Jellyfin answers 404 for an album without one; the views show a blank disc then.
    func artwork(_ itemId: String, size: Int = 600) -> URL? {
        URL(string: "\(server)/Items/\(itemId)/Images/Primary?fillWidth=\(size)&fillHeight=\(size)&quality=90")
    }

    /// Direct play when the phone can decode the file, else Jellyfin transcodes to AAC over HLS.
    /// The token travels in the query because AVPlayer sends no headers of ours.
    func stream(_ track: Track) -> URL? {
        URL(string: "\(server)/Audio/\(track.id)/universal?userId=\(userId)&deviceId=\(Self.deviceId)&api_key=\(token)"
            + "&container=mp3,aac,m4a%7Caac,m4b%7Caac,flac,alac,m4a%7Calac,wav,aiff"
            + "&transcodingContainer=ts&transcodingProtocol=hls&audioCodec=aac&maxStreamingBitrate=100000000")
    }

    static func authorization(token: String?) -> String {
        var header = "MediaBrowser Client=\"Spin\", Device=\"iPhone\", DeviceId=\"\(deviceId)\", Version=\"1.0\""
        if let token { header += ", Token=\"\(token)\"" }
        return header
    }

    static func decode<T: Decodable>(_ data: Data) throws -> [T] {
        try decoder.decode(Page<T>.self, from: data).items
    }

    private func items<T: Decodable>(_ query: String) async throws -> [T] {
        guard let url = URL(string: "\(server)/Items?userId=\(userId)&\(query)") else { throw JellyfinError.badServer }
        var request = URLRequest(url: url)
        request.setValue(Self.authorization(token: token), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw JellyfinError.status(code) }
        return try Self.decode(data)
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
