import CarPlay
import Combine
import UIKit

/// Spin on the car screen, laid out like Spotify's CarPlay app: tabs along the top (Home, Songs, Artists),
/// a row of cover art for what was added lately, and the system Now Playing screen with shuffle, repeat
/// and Up Next. CarPlay only allows Apple's templates, so the ZZZ look stays on the phone; the pink tint carries over.
@MainActor final class SpinCarPlayScene: NSObject, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver {
    private var controller: CPInterfaceController?
    private let home = CPListTemplate(title: "Home", sections: [])
    private let songsTab = CPListTemplate(title: "Songs", sections: [])
    private let artistsTab = CPListTemplate(title: "Artists", sections: [])
    private var songs: [Track] = []
    /// Every list row showing a song, so the playing one gets the equaliser marker wherever it appears.
    private var rows: [(id: String, item: CPListItem)] = []
    private var art: [String: UIImage] = [:]
    private var bag = Set<AnyCancellable>()

    private var session: Session { Shared.session }
    private var player: Player { Shared.player }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        controller = interfaceController
        home.tabImage = UIImage(systemName: "house.fill")
        songsTab.tabImage = UIImage(systemName: "music.note.list")
        artistsTab.tabImage = UIImage(systemName: "music.mic")
        for list in [home, songsTab, artistsTab] {
            list.emptyViewTitleVariants = ["Loading…"]
        }
        interfaceController.setRootTemplate(CPTabBarTemplate(templates: [home, songsTab, artistsTab]), animated: false, completion: nil)

        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.upNextTitle = "Up Next"
        nowPlaying.add(self)
        nowPlaying.updateNowPlayingButtons([
            CPNowPlayingShuffleButton { _ in Task { @MainActor in Shared.player.toggleShuffle() } },
            CPNowPlayingRepeatButton { _ in Task { @MainActor in Shared.player.cycleRepeat() } },
        ])

        // Signing in or out on the phone, or a new song starting, redraws the car screen.
        session.$client.receive(on: RunLoop.main).sink { [weak self] _ in Task { await self?.reload() } }.store(in: &bag)
        player.$transport.map(\.index).removeDuplicates().combineLatest(player.$queue)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.markPlaying() }.store(in: &bag)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        CPNowPlayingTemplate.shared.remove(self)
        bag.removeAll()
        rows = []
        controller = nil
    }

    // MARK: Lists

    private func reload() async {
        guard let client = session.client else {
            songs = []
            for list in [home, songsTab, artistsTab] {
                list.emptyViewTitleVariants = ["Sign in on your iPhone"]
                list.updateSections([])
            }
            return
        }
        do {
            songs = try await client.songs()
        } catch {
            for list in [home, songsTab, artistsTab] {
                list.emptyViewTitleVariants = ["Can't reach your music"]
                list.emptyViewSubtitleVariants = ["Check Tailscale on your iPhone"]
            }
            return
        }
        for list in [home, songsTab, artistsTab] {
            list.emptyViewTitleVariants = ["No songs yet"]
            list.emptyViewSubtitleVariants = ["Add some from the + on your iPhone"]
        }
        rows = []
        home.updateSections(homeSections())
        songsTab.updateSections(alphabetical(songs))
        artistsTab.updateSections(artistSections())
        markPlaying()
    }

    /// Spotify's Home: a shelf of covers, a big shuffle, then the newest songs.
    private func homeSections() -> [CPListSection] {
        guard !songs.isEmpty else { return [] }
        let recent = Array(songs.prefix(CPMaximumNumberOfGridImages))
        let placeholder = UIImage(systemName: "opticaldisc.fill")!
        let shelf = CPListImageRowItem(text: "Recently added", images: recent.map { art[$0.artId] ?? placeholder })
        shelf.listImageRowHandler = { [weak self] _, index, done in
            Task { @MainActor in self?.start(recent, at: index) }
            done()
        }
        shelf.handler = { [weak self] _, done in
            Task { @MainActor in self?.push(title: "Recently added", tracks: Array(self?.songs.prefix(100) ?? [])) }
            done()
        }
        for track in recent where art[track.artId] == nil {
            image(for: track) { [weak shelf, weak self] _ in
                guard let self else { return }
                shelf?.update(recent.map { self.art[$0.artId] ?? placeholder })
            }
        }
        let shuffleAll = CPListItem(text: "Shuffle all", detailText: "\(songs.count) songs", image: UIImage(systemName: "shuffle"))
        shuffleAll.handler = { [weak self] _, done in
            Task { @MainActor in
                guard let self else { return }
                self.start(self.songs, at: Int.random(in: 0..<self.songs.count), shuffled: true)
            }
            done()
        }
        let newest = Array(songs.prefix(12))
        return [CPListSection(items: [shelf, shuffleAll]),
                CPListSection(items: newest.enumerated().map { songItem($1, in: newest, at: $0) }, header: "New in your library", sectionIndexTitle: nil)]
    }

    /// A–Z with the letter index down the side, the way Spotify's Liked Songs scrolls in the car.
    private func alphabetical(_ tracks: [Track]) -> [CPListSection] {
        let sorted = tracks.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(CPListTemplate.maximumItemCount)
        let all = Array(sorted)
        let groups = Dictionary(grouping: all.indices) { letter(all[$0].name) }
        return groups.keys.sorted().prefix(CPListTemplate.maximumSectionCount).map { key in
            CPListSection(items: groups[key]!.map { songItem(all[$0], in: all, at: $0) }, header: key, sectionIndexTitle: key)
        }
    }

    private func artistSections() -> [CPListSection] {
        let byArtist = Dictionary(grouping: songs) { $0.artists?.first ?? "Unknown artist" }
        let names = byArtist.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .prefix(CPListTemplate.maximumItemCount)
        let items: [CPListItem] = names.map { name in
            let tracks = byArtist[name]!
            let item = CPListItem(text: name, detailText: tracks.count == 1 ? "1 song" : "\(tracks.count) songs",
                                  image: UIImage(systemName: "person.crop.circle.fill"))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, done in
                Task { @MainActor in self?.push(title: name, tracks: tracks, shuffleRow: true) }
                done()
            }
            if let first = tracks.first { image(for: first) { [weak item] in item?.setImage($0) } }
            return item
        }
        return [CPListSection(items: items)]
    }

    private func push(title: String, tracks: [Track], shuffleRow: Bool = false) {
        var sections: [CPListSection] = []
        if shuffleRow {
            let shuffle = CPListItem(text: "Shuffle", detailText: nil, image: UIImage(systemName: "shuffle"))
            shuffle.handler = { [weak self] _, done in
                Task { @MainActor in self?.start(tracks, at: Int.random(in: 0..<tracks.count), shuffled: true) }
                done()
            }
            sections.append(CPListSection(items: [shuffle]))
        }
        let shown = Array(tracks.prefix(CPListTemplate.maximumItemCount))
        sections.append(CPListSection(items: shown.enumerated().map { songItem($1, in: shown, at: $0) }))
        controller?.pushTemplate(CPListTemplate(title: title, sections: sections), animated: true, completion: nil)
    }

    private func songItem(_ track: Track, in list: [Track], at index: Int) -> CPListItem {
        let item = CPListItem(text: track.name, detailText: track.artist, image: art[track.artId])
        item.playingIndicatorLocation = .trailing
        item.handler = { [weak self] _, done in
            Task { @MainActor in self?.start(list, at: index) }
            done()
        }
        if art[track.artId] == nil { image(for: track) { [weak item] in item?.setImage($0) } }
        rows.append((track.id, item))
        return item
    }

    // MARK: Playback

    private func start(_ tracks: [Track], at index: Int, shuffled: Bool? = nil) {
        guard let client = session.client, tracks.indices.contains(index) else { return }
        player.play(tracks, at: index, via: client, shuffled: shuffled)
        showNowPlaying()
    }

    private func showNowPlaying() {
        guard let controller, !(controller.topTemplate is CPNowPlayingTemplate) else { return }
        controller.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func markPlaying() {
        let current = player.current?.id
        for row in rows { row.item.isPlaying = row.id == current }
    }

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in
            let queue = player.queue
            let from = player.transport.index
            let upcoming = Array(queue.indices.dropFirst(from + 1).prefix(CPListTemplate.maximumItemCount))
            let items: [CPListItem] = upcoming.map { i in
                let item = CPListItem(text: queue[i].name, detailText: queue[i].artist, image: art[queue[i].artId])
                item.handler = { [weak self] _, done in
                    Task { @MainActor in
                        Shared.player.jump(to: i)
                        self?.controller?.popTemplate(animated: true, completion: nil)
                    }
                    done()
                }
                return item
            }
            let list = CPListTemplate(title: "Up Next", sections: [CPListSection(items: items)])
            list.emptyViewTitleVariants = ["Nothing after this song"]
            controller?.pushTemplate(list, animated: true, completion: nil)
        }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}

    // MARK: Artwork

    /// Cover art sized for a list row, fetched once per picture.
    private func image(for track: Track, then set: @escaping (UIImage) -> Void) {
        guard let url = session.client?.artwork(for: track, size: 240) else { return }
        let key = track.artId  // shortcut: a cover changed on the phone shows in the car after reconnecting
        Task {
            if let cached = art[key] { set(cached); return }
            guard let data = try? await URLSession.shared.data(from: url).0, let image = UIImage(data: data) else { return }
            let size = CPListItem.maximumImageSize
            let fitted = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            art[key] = fitted
            set(fitted)
        }
    }
}
