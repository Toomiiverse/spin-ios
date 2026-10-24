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

    var current: Track? { queue.indices.contains(transport.index) ? queue[transport.index] : nil }
    var duration: Double { current?.seconds ?? 0 }
    var time: Double { transport.time }

    private let av = AVPlayer()
    private var client: Jellyfin?
    private var observers: [Any] = []
    private var bag = Set<AnyCancellable>()

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

    func play(_ tracks: [Track], at index: Int, via client: Jellyfin) {
        self.client = client
        queue = tracks
        transport = Transport(count: tracks.count, index: index)
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
        ]
        guard let albumId = track.albumId, let url = client?.artwork(albumId) else { return }
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

    private func remoteCommands() {
        let center = MPRemoteCommandCenter.shared()
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
