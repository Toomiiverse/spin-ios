import AVFoundation
import MediaPlayer
import UIKit
import Combine

/// The deck: one AVPlayer, the current disc (an album's tracks), lock-screen controls.
@MainActor final class Player: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var transport = Transport(count: 0)
    /// Follows the AVPlayer itself, so a phone call pausing playback shows as paused here too.
    @Published private(set) var playing = false
    @Published private(set) var shuffle = false

    var current: Track? { queue.indices.contains(transport.index) ? queue[transport.index] : nil }
    var duration: Double { current?.seconds ?? 0 }
    var time: Double { transport.time }

    private let av = AVPlayer()
    private var client: Jellyfin?
    private var observers: [Any] = []
    private var bag = Set<AnyCancellable>()
    /// The queue as it was picked, so shuffle off puts it back.
    private var picked: [Track] = []

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        observers.append(av.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.ended() }
        })
        av.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.playing = status != .paused
                self?.publishRate()
            }
            .store(in: &bag)
        remoteCommands()
    }

    /// Plays `tracks` from `index`; with shuffle on, that song first and the rest mixed.
    func play(_ tracks: [Track], at index: Int, via client: Jellyfin, shuffled: Bool? = nil) {
        self.client = client
        if let shuffled { shuffle = shuffled }
        picked = tracks
        queue = shuffle ? shuffledKeeping(tracks, first: index) : tracks
        transport = Transport(count: tracks.count, index: shuffle ? 0 : index, repeatMode: transport.repeatMode)
        load()
        publishModes()
    }

    func toggleShuffle() {
        shuffle.toggle()
        if let playing = current {
            queue = shuffle ? shuffledKeeping(picked, first: picked.firstIndex(of: playing) ?? 0) : picked
            transport.index = queue.firstIndex(of: playing) ?? 0
        }
        publishModes()
    }

    func cycleRepeat() {
        transport.cycleRepeat()
        publishModes()
    }

    /// Jump to a song already in the queue (CarPlay's Up Next).
    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        transport.index = index
        transport.time = 0
        load()
    }

    func toggle() { playing ? pause() : resume() }

    func resume() {
        guard current != nil else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        av.play()
    }

    func pause() { av.pause() }

    func next() {
        transport.skipForward()
        load()
    }

    func previous() {
        let before = transport.index
        transport.skipBack()
        if transport.index == before { seek(to: 0) } else { load() }
    }

    func seek(to seconds: Double) {
        av.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        transport.time = seconds
        publishRate()
    }

    private func load() {
        guard let track = current, let url = client?.stream(track) else { return }
        av.replaceCurrentItem(with: AVPlayerItem(url: url))
        resume()
        publishNowPlaying(track)
    }

    private func tick(_ seconds: Double) {
        if seconds.isFinite { transport.time = seconds }
    }

    private func ended() {
        if transport.ended() { load() } else { pause(); seek(to: 0) }
    }

    private func publishNowPlaying(_ track: Track) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.name,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album ?? "",
            MPMediaItemPropertyPlaybackDuration: track.seconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: transport.index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
        ]
        guard let url = client?.artwork(track.artId) else { return }
        Task {
            let data = try? await URLSession.shared.data(from: url).0
            // The disc may have changed while the picture loaded.
            guard let data, let image = UIImage(data: data), current?.id == track.id else { return }
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
    }

    private func publishRate() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = transport.time
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// The shuffle and repeat state CarPlay's Now Playing buttons and the lock screen show.
    private func publishModes() {
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType = shuffle ? .items : .off
        switch transport.repeatMode {
        case .off: center.changeRepeatModeCommand.currentRepeatType = .off
        case .all: center.changeRepeatModeCommand.currentRepeatType = .all
        case .one: center.changeRepeatModeCommand.currentRepeatType = .one
        }
    }

    private func remoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let type = (event as? MPChangeShuffleModeCommandEvent)?.shuffleType else { return .commandFailed }
            Task { @MainActor in if let self, (type != .off) != self.shuffle { self.toggleShuffle() } }
            return .success
        }
        center.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let type = (event as? MPChangeRepeatModeCommandEvent)?.repeatType else { return .commandFailed }
            Task { @MainActor in
                guard let self else { return }
                let wanted: Transport.Repeat = type == .one ? .one : type == .all ? .all : .off
                while self.transport.repeatMode != wanted { self.transport.cycleRepeat() }
                self.publishModes()
            }
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }
}
