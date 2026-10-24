import SwiftUI

/// The archive: every song on the server, newest first. A tap plays from that song down the list.
struct LibraryView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player
    @State private var songs: [Track] = []
    @State private var filter = ""
    @State private var error: String?
    @State private var showPlayer = false
    @State private var showAdd = false
    @State private var editing: Track?
    @State private var deleting: Track?

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
                            guard let client = session.client else { return }
                            player.play(shown, at: i, via: client)
                            showPlayer = true
                        } label: {
                            SongRow(track: track, current: player.current?.id == track.id)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash") { deleting = track }.tint(.red)
                            Button("Edit", systemImage: "pencil") { editing = track }.tint(Ink.pink)
                        }
                        .contextMenu {
                            Button("Edit details and cover", systemImage: "pencil") { editing = track }
                            Button("Delete from library", systemImage: "trash", role: .destructive) { deleting = track }
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
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign out") { session.signOut() }.caps(12)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus").font(.headline) }
                        .accessibilityLabel("Add music")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if player.current != nil { MiniBar().onTapGesture { showPlayer = true } }
            }
            .fullScreenCover(isPresented: $showPlayer) { PlayerView() }
            // New downloads reach Jellyfin a minute or so after they finish; reload on the way back and on pull.
            .sheet(isPresented: $showAdd, onDismiss: { Task { await load() } }) {
                AddView(library: songs) { await load() }.environmentObject(session)
            }
            .sheet(item: $editing) { track in
                EditSongView(track: track) { await load() }.environmentObject(session)
            }
            .confirmationDialog("Delete \(deleting?.name ?? "this song")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { track in
                Button("Delete the file", role: .destructive) { Task { await delete(track) } }
            } message: { _ in
                Text("It is removed from the server for good. You can download it again later.")
            }
            .task { await load() }
            // A pull rescans the server first, so anything added outside the app shows up too.
            .refreshable {
                if let client = session.client { try? await Sources().refreshLibrary(client) }
                try? await Task.sleep(for: .seconds(2))
                await load()
            }
        }
        .tint(Ink.pink)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Archives").caps(42).foregroundStyle(.white)
            HStack(spacing: 10) {
                Slant(skew: 5).fill(Ink.pink).frame(width: 56, height: 8)
                Text("\(songs.count) songs").caps(12).foregroundStyle(Ink.pink)
            }
            TextField("Filter", text: $filter)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(10).background(Ink.panel, in: Slant())
            Hazard().frame(height: 8).padding(.top, 4)
        }
        .padding(.vertical, 8)
    }

    private func delete(_ track: Track) async {
        guard let client = session.client else { return }
        do {
            try await Sources().delete(track, via: client)
            songs.removeAll { $0.id == track.id }
            if player.current?.id == track.id { player.queue.count > 1 ? player.next() : player.pause() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            songs = try await client.songs()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SongRow: View {
    @EnvironmentObject private var session: Session
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
