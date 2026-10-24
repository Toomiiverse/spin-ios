import Foundation

/// Songs kept on the phone: the original file from Jellyfin plus its details, so they play and list with no connection.
@MainActor final class Downloads: ObservableObject {
    @Published private(set) var saved: [Track] = []
    @Published private(set) var busy = Set<String>()

    private let dir = URL.documentsDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
    private var index: URL { dir.appending(path: "index.json") }

    init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        saved = (try? JSONDecoder().decode([Track].self, from: Data(contentsOf: index))) ?? []
    }

    /// The file on the phone, named by song id with the server file's extension so AVPlayer knows the format.
    func file(_ track: Track) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path())) ?? []
        return names.first { ($0 as NSString).deletingPathExtension == track.id }.map { dir.appending(path: $0) }
    }

    func has(_ track: Track) -> Bool { saved.contains { $0.id == track.id } }

    /// One at a time, so a long list doesn't open dozens of transfers over Tailscale.
    func save(_ tracks: [Track], via client: Jellyfin) async throws {
        for track in unique(tracks) where !has(track) && !busy.contains(track.id) {
            busy.insert(track.id)
            defer { busy.remove(track.id) }
            guard let url = client.download(track) else { continue }
            let (temp, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw JellyfinError.status((response as? HTTPURLResponse)?.statusCode ?? 0) }
            let ext = response.suggestedFilename.map { ($0 as NSString).pathExtension } ?? "m4a"
            try FileManager.default.moveItem(at: temp, to: dir.appending(path: "\(track.id).\(ext.isEmpty ? "m4a" : ext)"))
            var plain = track
            plain.playlistItemId = nil
            saved.insert(plain, at: 0)
            write()
        }
    }

    func remove(_ track: Track) {
        if let file = file(track) { try? FileManager.default.removeItem(at: file) }
        saved.removeAll { $0.id == track.id }
        write()
    }

    private func write() { try? JSONEncoder().encode(saved).write(to: index, options: .atomic) }
}
