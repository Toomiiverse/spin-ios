import SwiftUI

/// The deck, after the Discman: the disc under a lid with a vertical LCD, a dark panel with the transport, a hazard-striped title card.
struct PlayerView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Double?

    private var track: Track? { player.current }
    private var art: URL? { track.flatMap { session.client?.artwork($0.artId) } }

    var body: some View {
        ZStack {
            Ink.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    top
                    lid
                    deck
                    card
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private var top: some View {
        HStack(spacing: 10) {
            Text(String(format: "No.%02d", player.transport.index + 1)).caps(14).foregroundStyle(Ink.pink)
            Text(track?.album ?? "").caps(14).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.headline).foregroundStyle(.white).frame(width: 44, height: 44)
            }
        }
    }

    private var lid: some View {
        HStack(spacing: 10) {
            VStack(spacing: 12) {
                Text(clock(player.time))
                    .font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Ink.lcd, in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize()
                    .rotationEffect(.degrees(90))
                    .frame(width: 44, height: 112)
                Text(track?.artist ?? "").caps(11).foregroundStyle(Ink.pink).lineLimit(1)
                    .frame(width: 110)
                    .rotationEffect(.degrees(90))
                    .frame(width: 44, height: 110)
                Spacer()
                Rectangle().fill(Ink.pink).frame(width: 5, height: 36)
            }
            .frame(width: 44)
            Spacer(minLength: 0)
            Disc(art: art, spinning: player.playing, size: 240)
                .shadow(color: Ink.pink.opacity(0.35), radius: 24)
        }
        .padding(16)
        .frame(height: 290)
        .background(Ink.deck, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private var deck: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(player.playing ? Ink.neonGreen : Ink.pink).frame(width: 6, height: 6)
                Circle().fill(.white.opacity(0.2)).frame(width: 6, height: 6)
                Circle().fill(.white.opacity(0.2)).frame(width: 6, height: 6)
                Text(player.playing ? "Play" : "Pause").caps(11).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Image(systemName: "star.fill").foregroundStyle(Ink.neonYellow)
                Image(systemName: "music.note").foregroundStyle(Ink.pink)
                Image(systemName: "pill.fill").foregroundStyle(Ink.neonGreen).rotationEffect(.degrees(-35))
            }
            .font(.caption)
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Spin · Now playing").caps(10).foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    Text("\(clock(player.time)) / \(clock(player.duration))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                }
                Text(track?.name ?? "No disc").font(.system(size: 22, weight: .heavy)).italic()
                    .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.7)
                Text(track?.artist ?? "").caps(12).foregroundStyle(Ink.pink).lineLimit(1)
                Slider(value: Binding(get: { scrubbing ?? player.time }, set: { scrubbing = $0 }),
                       in: 0...max(1, player.duration),
                       onEditingChanged: { editing in
                           if !editing, let target = scrubbing { player.seek(to: target); scrubbing = nil }
                       })
                .tint(Ink.pink)
                HStack {
                    control("backward.end.fill") { player.previous() }
                    Spacer()
                    control(player.playing ? "pause.fill" : "play.fill", size: 36) { player.toggle() }
                    Spacer()
                    control("forward.end.fill") { player.next() }
                }
                .padding(.horizontal, 24)
            }
            .padding(16)
            .background(Color(red: 0.055, green: 0.055, blue: 0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
        .padding(12)
        .background(Ink.deck, in: RoundedRectangle(cornerRadius: 16))
    }

    private var card: some View {
        VStack(spacing: 0) {
            Hazard().frame(height: 10)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.album ?? "").caps(24).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6)
                    Text(track?.artist ?? "").caps(12).foregroundStyle(.black.opacity(0.75))
                }
                Spacer()
                Text(String(format: "%02d / %02d", player.transport.index + 1, player.transport.count))
                    .font(.system(size: 12, weight: .black, design: .monospaced)).foregroundStyle(.black)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.white, in: Slant(skew: 4))
            }
            .padding(14)
            .background(Ink.pink)
        }
        .clipShape(Slant(skew: 10))
    }

    private func control(_ symbol: String, size: CGFloat = 22, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .bold)).foregroundStyle(.white).frame(width: 60, height: 50)
        }
    }
}
