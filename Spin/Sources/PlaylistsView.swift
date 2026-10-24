import SwiftUI

/// Jellyfin's own playlists, so they show up in any Jellyfin app too.
struct PlaylistsView: View {
    @EnvironmentObject private var session: Session
    let play: (_ tracks: [Track], _ index: Int, _ shuffled: Bool?) -> Void
    @State private var playlists: [Playlist] = []
    @State private var error: String?
    @State private var naming = false
    @State private var name = ""
    @State private var deleting: Playlist?

    var body: some View {
        List {
            Section {
                ForEach(playlists) { playlist in
                    NavigationLink { PlaylistView(playlist: playlist, play: play) } label: { PlaylistRow(playlist: playlist) }
                        .swipeActions { Button("Delete", systemImage: "trash") { deleting = playlist }.tint(.red) }
                        .contextMenu { Button("Delete playlist", systemImage: "trash", role: .destructive) { deleting = playlist } }
                }
            } header: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Playlists").caps(42).foregroundStyle(.white)
                    Hazard().frame(height: 8)
                }
                .padding(.vertical, 8)
            }
            .listRowBackground(Ink.black)
            .listRowSeparatorTint(Ink.panel)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Ink.black)
        .overlay {
            if let error { Text(error).caps(14).foregroundStyle(Ink.pink).padding() }
            else if playlists.isEmpty { Text("No playlists yet. Tap + or select songs").caps(14).foregroundStyle(.secondary).multilineTextAlignment(.center).padding() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { name = ""; naming = true } label: { Image(systemName: "plus").font(.headline) }
                .accessibilityLabel("New playlist")
        }
        .alert("New playlist", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Create") { Task { await create() } }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(deleting?.name ?? "this playlist")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { playlist in
            Button("Delete playlist", role: .destructive) { Task { await delete(playlist) } }
        } message: { _ in
            Text("The songs stay in your library.")
        }
        // Runs again on the way back from a playlist, so the counts are current.
        .task { await load() }
        .refreshable { await load() }
    }

    private func create() async {
        guard let client = session.client else { return }
        do {
            try await client.createPlaylist(name.trimmingCharacters(in: .whitespaces), songs: [])
            await load()
        } catch { self.error = error.localizedDescription }
    }

    private func delete(_ playlist: Playlist) async {
        guard let client = session.client else { return }
        do {
            try await client.delete(playlist)
            playlists.removeAll { $0.id == playlist.id }
        } catch { self.error = error.localizedDescription }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            playlists = try await client.playlists()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct PlaylistRow: View {
    @EnvironmentObject private var session: Session
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            Cover(url: session.client?.artwork(playlist.id, size: 160, tag: playlist.imageTags?["Primary"]), size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name).font(.system(size: 16, weight: .heavy)).foregroundStyle(.white).lineLimit(1)
                Text(songCount(playlist.childCount ?? 0)).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// One playlist: play it in order or shuffled; swipe a song to take it out.
struct PlaylistView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player
    let playlist: Playlist
    let play: (_ tracks: [Track], _ index: Int, _ shuffled: Bool?) -> Void
    @State private var songs: [Track] = []
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(Array(songs.enumerated()), id: \.element.playlistItemId) { i, track in
                    Button { play(songs, i, nil) } label: { SongRow(track: track, current: player.current?.id == track.id) }
                        .swipeActions { Button("Remove", systemImage: "minus.circle") { Task { await remove(track) } }.tint(.red) }
                        .contextMenu { Button("Remove from playlist", systemImage: "minus.circle", role: .destructive) { Task { await remove(track) } } }
                }
            } header: {
                VStack(alignment: .leading, spacing: 10) {
                    Text(playlist.name).caps(34).foregroundStyle(.white).lineLimit(2)
                    Text(songCount(songs.count)).caps(12).foregroundStyle(Ink.pink)
                    HStack(spacing: 10) {
                        big("Play", "play.fill") { play(songs, 0, false) }
                        big("Shuffle", "shuffle") { play(songs, Int.random(in: 0..<songs.count), true) }
                    }
                    .disabled(songs.isEmpty)
                    Hazard().frame(height: 8)
                }
                .padding(.vertical, 8)
            }
            .listRowBackground(Ink.black)
            .listRowSeparatorTint(Ink.panel)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Ink.black)
        .overlay {
            if let error { Text(error).caps(14).foregroundStyle(Ink.pink).padding() }
            else if songs.isEmpty { Text("Empty. Select songs in your library to add them").caps(14).foregroundStyle(.secondary).multilineTextAlignment(.center).padding() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func big(_ label: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon).caps(15)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Ink.pink, in: Slant()).foregroundStyle(.black)
        }
        .buttonStyle(.plain)
    }

    private func remove(_ track: Track) async {
        guard let client = session.client else { return }
        do {
            try await client.remove([track], from: playlist)
            songs.removeAll { $0.playlistItemId == track.playlistItemId }
        } catch { self.error = error.localizedDescription }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            songs = try await client.songs(in: playlist)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

/// Pick a playlist for the chosen songs, or start a new one with them. Songs already in it are skipped.
struct AddToPlaylistView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    let songs: [Track]
    let added: () -> Void
    @State private var playlists: [Playlist] = []
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Ink.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Add \(songCount(songs.count))").caps(30).foregroundStyle(.white)
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.headline).foregroundStyle(.white).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Close")
                    }
                    Hazard().frame(height: 8)
                    HStack(spacing: 10) {
                        TextField("New playlist", text: $name)
                            .padding(10).background(Ink.panel, in: Slant())
                        Button { Task { await create() } } label: {
                            Text("Create").caps(15).padding(.horizontal, 16).padding(.vertical, 10)
                                .background(Ink.pink, in: Slant()).foregroundStyle(.black)
                        }
                        .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let error { Text(error).font(.footnote.weight(.semibold)).foregroundStyle(Ink.pink) }
                    ForEach(playlists) { playlist in
                        Button { Task { await add(to: playlist) } } label: {
                            HStack { PlaylistRow(playlist: playlist); Spacer(); Image(systemName: "plus.circle").foregroundStyle(Ink.pink) }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                }
                .padding(16)
            }
        }
        .task {
            do { playlists = try await session.client?.playlists() ?? [] }
            catch { self.error = error.localizedDescription }
        }
    }

    private func create() async {
        await run { try await $0.createPlaylist(name.trimmingCharacters(in: .whitespaces), songs: unique(songs)) }
    }

    private func add(to playlist: Playlist) async {
        await run { client in
            let have = Set(try await client.songs(in: playlist).map(\.id))
            let new = unique(songs).filter { !have.contains($0.id) }
            if !new.isEmpty { try await client.add(new, to: playlist) }
        }
    }

    private func run(_ work: (Jellyfin) async throws -> Void) async {
        guard let client = session.client else { return }
        busy = true
        defer { busy = false }
        do {
            try await work(client)
            added()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
