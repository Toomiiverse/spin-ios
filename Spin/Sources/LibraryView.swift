import SwiftUI

/// The archive: every song on the server, newest first. A tap plays from that song down the list;
/// in select mode taps tick songs instead, for adding to a playlist or deleting together.
struct LibraryView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: Downloads
    @State private var songs: [Track] = []
    @State private var filter = ""
    @State private var error: String?
    @State private var showPlayer = false
    @State private var showAdd = false
    @State private var showDiscover = false
    @State private var showPlaylists = false
    @State private var editing: Track?
    @State private var deleting: [Track] = []
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var adding: [Track] = []

    private var picked: [Track] { songs.filter { selected.contains($0.id) } }

    private var shown: [Track] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return songs }
        return songs.filter { "\($0.name) \($0.artist) \($0.album ?? "")".localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, track in
                        Button {
                            if selecting {
                                if selected.remove(track.id) == nil { selected.insert(track.id) }
                            } else {
                                start(shown, at: i)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                if selecting {
                                    Image(systemName: selected.contains(track.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3).foregroundStyle(Ink.pink)
                                }
                                SongRow(track: track, current: player.current?.id == track.id)
                            }
                        }
                        .accessibilityAddTraits(selecting && selected.contains(track.id) ? .isSelected : [])
                        .swipeActions(edge: .trailing) {
                            if !selecting {
                                Button("Delete", systemImage: "trash") { deleting = [track] }.tint(.red)
                                Button("Edit", systemImage: "pencil") { editing = track }.tint(Ink.pink)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if !selecting { Button("Playlist", systemImage: "text.badge.plus") { adding = [track] }.tint(Ink.pink) }
                        }
                        .contextMenu {
                            if !selecting {
                                Button("Add to playlist", systemImage: "text.badge.plus") { adding = [track] }
                                if downloads.has(track) {
                                    Button("Remove from phone", systemImage: "iphone.slash") { downloads.remove(track) }
                                } else {
                                    Button("Download to phone", systemImage: "arrow.down.circle") { save([track]) }
                                }
                                Button("Select", systemImage: "checkmark.circle") { selecting = true; selected = [track.id] }
                                Button("Edit details and cover", systemImage: "pencil") { editing = track }
                                Button("Delete from library", systemImage: "trash", role: .destructive) { deleting = [track] }
                            }
                        }
                    }
                } header: {
                    header
                }
                .listRowBackground(Ink.black)
                .listRowSeparatorTint(Ink.panel)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Ink.black)
            .overlay {
                if let error { Text(error).caps(14).foregroundStyle(Ink.pink).padding() }
                else if songs.isEmpty { Text("No songs yet. Tap + to add some").caps(14).foregroundStyle(.secondary) }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Ink.black, for: .navigationBar)
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .topBarLeading) {
                        let all = !shown.isEmpty && shown.allSatisfy { selected.contains($0.id) }
                        Button(all ? "None" : "All") { selected = all ? [] : selected.union(shown.map(\.id)) }.caps(12)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { selecting = false; selected = [] }.caps(12)
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Sign out") { session.signOut() }.caps(12)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Select") { selecting = true }.caps(12).disabled(songs.isEmpty)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showDiscover = true } label: { Image(systemName: "sparkles").font(.headline) }
                            .accessibilityLabel("Discover")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showAdd = true } label: { Image(systemName: "plus").font(.headline) }
                            .accessibilityLabel("Add music")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting { selectionBar }
            }
            // New downloads reach Jellyfin a minute or so after they finish; reload on the way back and on pull.
            .sheet(isPresented: $showDiscover, onDismiss: { Task { await load() } }) {
                DiscoverView().environmentObject(session)
            }
            .sheet(isPresented: $showAdd, onDismiss: { Task { await load() } }) {
                AddView(library: songs) { await load() }.environmentObject(session)
            }
            .sheet(item: $editing) { track in
                EditSongView(track: track) { await load() }.environmentObject(session)
            }
            .sheet(isPresented: Binding(get: { !adding.isEmpty }, set: { if !$0 { adding = [] } })) {
                AddToPlaylistView(songs: adding) { selecting = false; selected = [] }.environmentObject(session)
            }
            .confirmationDialog(deleting.count == 1 ? "Delete \(deleting[0].name)?" : "Delete \(deleting.count) songs?",
                                isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
                                titleVisibility: .visible, presenting: deleting) { tracks in
                Button(tracks.count == 1 ? "Delete the file" : "Delete \(tracks.count) files", role: .destructive) { Task { await delete(tracks) } }
            } message: { tracks in
                Text(tracks.count == 1 ? "It is removed from the server for good. You can download it again later."
                                       : "They are removed from the server for good. You can download them again later.")
            }
            .task { await load() }
            // A pull rescans the server first, so anything added outside the app shows up too.
            .refreshable {
                if let client = session.client { try? await Sources().refreshLibrary(client) }
                try? await Task.sleep(for: .seconds(2))
                await load()
            }
            .navigationDestination(isPresented: $showPlaylists) { PlaylistsView(play: start) }
        }
        // On the stack, not the list, so the mini player and the deck follow into playlists too.
        .safeAreaInset(edge: .bottom) {
            if player.current != nil && !selecting { MiniBar().onTapGesture { showPlayer = true } }
        }
        .fullScreenCover(isPresented: $showPlayer) { PlayerView() }
        .tint(Ink.pink)
    }

    private func start(_ tracks: [Track], at index: Int, shuffled: Bool? = nil) {
        guard let client = session.client, tracks.indices.contains(index) else { return }
        player.play(tracks, at: index, via: client, shuffled: shuffled)
        showPlayer = true
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("\(selected.count) selected").caps(14).foregroundStyle(.white)
            Spacer()
            Button { adding = picked } label: {
                Label("Playlist", systemImage: "text.badge.plus").caps(14).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Ink.pink, in: Slant()).foregroundStyle(.black)
            }
            Button { save(picked); selecting = false; selected = [] } label: {
                Image(systemName: "arrow.down.circle").font(.headline).foregroundStyle(.white).frame(width: 44, height: 40)
                    .background(Ink.panel, in: Slant())
            }
            .accessibilityLabel("Download selected to phone")
            Button { deleting = picked } label: {
                Image(systemName: "trash").font(.headline).foregroundStyle(.white).frame(width: 44, height: 40)
                    .background(Ink.panel, in: Slant())
            }
            .accessibilityLabel("Delete selected")
        }
        .buttonStyle(.plain)
        .disabled(selected.isEmpty)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Ink.deck)
        .overlay(alignment: .top) { Hazard().frame(height: 4) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Archives").caps(42).foregroundStyle(.white)
            HStack(spacing: 10) {
                Slant(skew: 5).fill(Ink.pink).frame(width: 56, height: 8)
                Text("\(songs.count) songs").caps(12).foregroundStyle(Ink.pink)
                Spacer()
                Button { showPlaylists = true } label: {
                    Label("Playlists", systemImage: "music.note.list").caps(13).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Ink.panel, in: Slant()).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(selecting)
            }
            TextField("Filter", text: $filter)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(10).background(Ink.panel, in: Slant())
            Hazard().frame(height: 8).padding(.top, 4)
        }
        .padding(.vertical, 8)
    }

    /// One at a time, so a failure part way keeps what was already deleted off the list.
    private func delete(_ tracks: [Track]) async {
        guard let client = session.client else { return }
        do {
            for track in tracks {
                try await Sources().delete(track, via: client)
                songs.removeAll { $0.id == track.id }
                selected.remove(track.id)
                if player.current?.id == track.id { player.queue.count > 1 ? player.next() : player.pause() }
            }
            if selected.isEmpty { selecting = false }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ tracks: [Track]) {
        guard let client = session.client else { return }
        Task {
            do { try await downloads.save(tracks, via: client) } catch { self.error = "Download failed: \(error.localizedDescription)" }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            songs = try await client.songs()
            error = nil
        } catch {
            // No connection: what is on the phone still plays.
            if songs.isEmpty && !downloads.saved.isEmpty { songs = downloads.saved } else { self.error = error.localizedDescription }
        }
    }
}

struct SongRow: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var downloads: Downloads
    let track: Track
    let current: Bool

    var body: some View {
        HStack(spacing: 12) {
            Cover(url: session.client?.artwork(for: track, size: 160), size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.name).font(.system(size: 16, weight: .heavy)).foregroundStyle(current ? Ink.pink : Color.white).lineLimit(1)
                Text(track.artist).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if downloads.busy.contains(track.id) {
                ProgressView().tint(Ink.pink).accessibilityLabel("Downloading")
            } else if downloads.has(track) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Ink.neonGreen).accessibilityLabel("On this phone")
            }
            Text(clock(track.seconds)).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// The strip above the bottom edge: what is playing, with play/pause and next.
struct MiniBar: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player

    var body: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                Disc(art: session.client?.artwork(for: track, size: 200), spinning: player.playing, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name).caps(15).foregroundStyle(.white).lineLimit(1)
                    Text(track.artist).font(.caption.weight(.semibold)).foregroundStyle(Ink.pink).lineLimit(1)
                }
                Spacer()
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title2).foregroundStyle(.white).frame(width: 44, height: 44)
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.end.fill").font(.title3).foregroundStyle(.white).frame(width: 40, height: 44)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Ink.deck)
            .overlay(alignment: .top) { Hazard().frame(height: 4) }
            .contentShape(Rectangle())
        }
    }
}
