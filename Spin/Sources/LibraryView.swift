import SwiftUI

/// The archive: every album on the server, each a disc to load.
struct LibraryView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player
    @State private var albums: [Album] = []
    @State private var error: String?
    @State private var showPlayer = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(albums) { album in
                        NavigationLink(value: album) { AlbumRow(album: album) }
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
                else if albums.isEmpty { Text("No discs yet").caps(14).foregroundStyle(.secondary) }
            }
            .navigationDestination(for: Album.self) { AlbumView(album: $0) }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Ink.black, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out") { session.signOut() }.caps(12)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if player.current != nil { MiniBar().onTapGesture { showPlayer = true } }
            }
            .fullScreenCover(isPresented: $showPlayer) { PlayerView() }
            .task { await load() }
            .refreshable { await load() }
        }
        .tint(Ink.pink)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Archives").caps(42).foregroundStyle(.white)
            HStack(spacing: 10) {
                Slant(skew: 5).fill(Ink.pink).frame(width: 56, height: 8)
                Text("\(albums.count) discs").caps(12).foregroundStyle(Ink.pink)
            }
            Hazard().frame(height: 8).padding(.top, 6)
        }
        .padding(.vertical, 8)
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            albums = try await client.albums()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AlbumRow: View {
    @EnvironmentObject private var session: Session
    let album: Album

    var body: some View {
        HStack(spacing: 14) {
            Cover(url: session.client?.artwork(album.id, size: 200))
            VStack(alignment: .leading, spacing: 4) {
                Text(album.name).caps(17).foregroundStyle(.white).lineLimit(2)
                Text([album.albumArtist, album.productionYear.map { String($0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

/// One album's tracks; a tap loads the album as the disc from that track.
struct AlbumView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player
    let album: Album
    @State private var tracks: [Track] = []
    @State private var showPlayer = false

    var body: some View {
        List {
            Section {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                    Button {
                        guard let client = session.client else { return }
                        player.play(tracks, at: i, via: client)
                        showPlayer = true
                    } label: {
                        TrackRow(track: track, number: i + 1, current: player.current?.id == track.id)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 10) {
                    Cover(url: session.client?.artwork(album.id), size: 180)
                    Text(album.name).caps(30).foregroundStyle(.white)
                    Text(album.albumArtist ?? "").caps(13).foregroundStyle(Ink.pink)
                    Hazard().frame(height: 6)
                }
                .padding(.vertical, 8)
            }
            .listRowBackground(Ink.black)
            .listRowSeparatorTint(Ink.panel)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Ink.black)
        .toolbarBackground(Ink.black, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            if player.current != nil { MiniBar().onTapGesture { showPlayer = true } }
        }
        .fullScreenCover(isPresented: $showPlayer) { PlayerView() }
        .task { tracks = (try? await session.client?.tracks(of: album)) ?? [] }
    }
}

struct TrackRow: View {
    let track: Track
    let number: Int
    let current: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text(String(format: "%02d", number))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(current ? Ink.pink : Color.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.name).font(.system(size: 16, weight: .heavy)).foregroundStyle(current ? Ink.pink : Color.white).lineLimit(1)
                Text(track.artist).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(clock(track.seconds)).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

/// The strip above the tab bar line: what is playing, with play/pause and next.
struct MiniBar: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player

    var body: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                Disc(art: track.albumId.flatMap { session.client?.artwork($0, size: 200) }, spinning: player.playing, size: 44)
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
