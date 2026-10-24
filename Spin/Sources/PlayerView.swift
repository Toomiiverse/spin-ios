import SwiftUI

/// The deck, after the Discman: the disc under a lid with a vertical LCD and stickers, the title once,
/// a thin scrubber, a slanted pink play key, and a hazard-striped card for what plays next.
/// Laid out to the screen's height, so nothing scrolls and nothing is left empty below.
struct PlayerView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss

    private var track: Track? { player.current }

    /// What the next-track button will play: the following song, or the first again when repeating the lot.
    private var upNext: Track? {
        let i = player.transport.index + 1
        if player.queue.indices.contains(i) { return player.queue[i] }
        return player.transport.repeatMode == .all ? player.queue.first : nil
    }

    var body: some View {
        GeometryReader { geo in
            // Width: page and lid padding, the LCD rail and the stack gaps take 136pt.
            // Height: the rest of the column needs about 430pt, so an SE still fits without scrolling.
            let disc = max(160, min(geo.size.width - 136, geo.size.height - 430))
            VStack(spacing: 0) {
                top
                Spacer(minLength: 6)
                lid(disc: disc)
                Spacer(minLength: 14)
                titles
                Scrubber(time: player.time, duration: player.duration) { player.seek(to: $0) }
                    .padding(.top, 14)
                transport.padding(.top, 6)
                Spacer(minLength: 10)
                card
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background { backdrop }
        // A pull down on the screen closes it, like the chevron.
        .gesture(DragGesture(minimumDistance: 30).onEnded { if $0.translation.height > 120 && abs($0.translation.width) < 80 { dismiss() } })
    }

    /// The cover, blurred and darkened, so each song tints the deck its own colour.
    private var backdrop: some View {
        ZStack {
            Ink.black
            if let track {
                AsyncImage(url: session.client?.artwork(for: track, size: 200)) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                    .blur(radius: 60).opacity(0.45)
                    .id(track.id)
                    .transition(.opacity)
            }
            LinearGradient(colors: [Ink.black.opacity(0.2), Ink.black.opacity(0.75), Ink.black], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: track?.id)
    }

    private var top: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.headline).foregroundStyle(.white).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            Spacer()
            Text(String(format: "No.%02d / %02d", player.transport.index + 1, player.transport.count))
                .caps(13).foregroundStyle(.white.opacity(0.7))
            Spacer()
            OnAir(playing: player.playing).frame(width: 44)
        }
    }

    private func lid(disc: CGFloat) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 14) {
                Text(clock(player.time))
                    .font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Ink.lcd, in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize()
                    .rotationEffect(.degrees(90))
                    .frame(width: 34, height: 104)
                    .accessibilityHidden(true)
                Spacer()
                // Three lamps: green while playing, pink while paused.
                ForEach(0..<3) { i in
                    Circle().fill(i == 0 ? (player.playing ? Ink.neonGreen : Ink.pink) : .white.opacity(0.18)).frame(width: 6, height: 6)
                }
            }
            .frame(width: 34)
            .padding(.vertical, 4)
            Spacer(minLength: 0)
            Disc(art: track.flatMap { session.client?.artwork(for: $0) }, spinning: player.playing, size: disc)
                .shadow(color: Ink.pink.opacity(player.playing ? 0.5 : 0.15), radius: player.playing ? 30 : 12)
                .animation(.easeInOut(duration: 0.8), value: player.playing)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(height: disc + 28)
        .background(Ink.deck.opacity(0.85), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            // Stickers slapped on the lid, as on the reference deck.
            HStack(spacing: 6) {
                Image(systemName: "star.fill").foregroundStyle(Ink.neonYellow).rotationEffect(.degrees(-12))
                Image(systemName: "music.note").foregroundStyle(Ink.pink)
                Image(systemName: "pill.fill").foregroundStyle(Ink.neonGreen).rotationEffect(.degrees(-35))
            }
            .font(.system(size: 15, weight: .bold))
            .padding(14)
            .accessibilityHidden(true)
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(track?.name ?? "No disc").font(.system(size: 26, weight: .heavy)).italic()
                .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.65)
            HStack(spacing: 8) {
                Slant(skew: 4).fill(Ink.pink).frame(width: 22, height: 6)
                Text(track?.artist ?? "").caps(14).foregroundStyle(Ink.pink).lineLimit(1)
                // SoundCloud singles name the album after the song; say it only when it adds something.
                if let album = track?.album, !album.isEmpty, album != track?.name {
                    Text("· \(album)").caps(14).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transport: some View {
        HStack(spacing: 0) {
            mode("shuffle", on: player.shuffle, label: "Shuffle") { player.toggleShuffle() }
            Spacer()
            control("backward.end.fill", label: "Previous") { player.previous() }
            Spacer()
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .black)).foregroundStyle(.black)
                    .frame(width: 84, height: 62)
                    .background(Ink.pink, in: Slant(skew: 10))
                    .shadow(color: Ink.pink.opacity(0.45), radius: 14)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(player.playing ? "Pause" : "Play")
            Spacer()
            control("forward.end.fill", label: "Next") { player.next() }
            Spacer()
            mode(player.transport.repeatMode == .one ? "repeat.1" : "repeat", on: player.transport.repeatMode != .off,
                 label: "Repeat") { player.cycleRepeat() }
        }
    }

    /// What comes next, on the pink card; a tap skips to it.
    private var card: some View {
        Button { player.next() } label: {
            VStack(spacing: 0) {
                Hazard().frame(height: 10)
                HStack(spacing: 12) {
                    if let upNext {
                        Cover(url: session.client?.artwork(for: upNext, size: 120), size: 42)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.4), lineWidth: 1))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Up next").caps(11).foregroundStyle(.black.opacity(0.6))
                        Text(upNext?.name ?? "End of the disc").caps(18).foregroundStyle(.white).lineLimit(1)
                        Text(upNext?.artist ?? "Turn on repeat to keep going").caps(11).foregroundStyle(.black.opacity(0.75)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if upNext != nil {
                        Image(systemName: "forward.fill").font(.system(size: 14, weight: .black)).foregroundStyle(.black)
                            .frame(width: 34, height: 26).background(.white, in: Slant(skew: 4))
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Ink.pink)
            }
            .clipShape(Slant(skew: 10))
        }
        .buttonStyle(.plain)
        .disabled(upNext == nil)
        .accessibilityLabel(upNext.map { "Up next: \($0.name) by \($0.artist). Skip to it" } ?? "End of the disc")
    }

    /// Shuffle and repeat: pink with a dot under it when on, like Spotify's green.
    private func mode(_ symbol: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 18, weight: .bold))
                Circle().frame(width: 4, height: 4).opacity(on ? 1 : 0)
            }
            .foregroundStyle(on ? Ink.pink : Color.white.opacity(0.6))
            .frame(width: 44, height: 50)
        }
        .accessibilityLabel(label)
        .accessibilityValue(on ? "On" : "Off")
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 26, weight: .bold)).foregroundStyle(.white).frame(width: 56, height: 56)
        }
        .accessibilityLabel(label)
    }
}

/// A thin pink bar that thickens under the finger; elapsed on the left, remaining on the right.
struct Scrubber: View {
    let time: Double
    let duration: Double
    let seek: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        let shown = min(duration, max(0, dragging ?? time))
        let fraction = duration > 0 ? shown / duration : 0
        VStack(spacing: 4) {
            GeometryReader { geo in
                let held = dragging != nil
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14)).frame(height: held ? 8 : 4)
                    Capsule().fill(Ink.pink).frame(width: max(0, geo.size.width * fraction), height: held ? 8 : 4)
                    RoundedRectangle(cornerRadius: 2).fill(.white)
                        .frame(width: held ? 6 : 4, height: held ? 22 : 14)
                        .offset(x: geo.size.width * fraction - (held ? 3 : 2))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { dragging = duration * min(1, max(0, $0.location.x / max(1, geo.size.width))) }
                    .onEnded { _ in
                        if let target = dragging { seek(target) }
                        dragging = nil
                    })
                .animation(.easeOut(duration: 0.15), value: held)
            }
            .frame(height: 26)
            HStack {
                Text(clock(shown))
                Spacer()
                Text("-" + clock(duration - shown))
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
        }
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(clock(shown)) of \(clock(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: seek(min(duration, time + 15))
            case .decrement: seek(max(0, time - 15))
            @unknown default: break
            }
        }
    }
}

/// Three bars that bounce while the disc plays and lie flat when it stops.
struct OnAir: View {
    let playing: Bool

    var body: some View {
        TimelineView(.animation(paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<3) { i in
                    let bounce = playing ? (sin(t * (5 + Double(i) * 1.7) + Double(i)) + 1) / 2 : 0
                    RoundedRectangle(cornerRadius: 1).fill(playing ? Ink.neonGreen : Color.white.opacity(0.35))
                        .frame(width: 4, height: 4 + 12 * bounce)
                }
            }
            .frame(height: 16, alignment: .bottom)
        }
        .accessibilityElement()
        .accessibilityLabel(playing ? "Playing" : "Paused")
    }
}
