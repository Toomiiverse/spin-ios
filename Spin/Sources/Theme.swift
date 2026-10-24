import SwiftUI

/// The palette: near-black deck, hot pink, LCD white and two sticker neons.
enum Ink {
    static let black = Color(red: 0.043, green: 0.043, blue: 0.055)
    static let deck = Color(red: 0.09, green: 0.09, blue: 0.11)
    static let panel = Color(red: 0.14, green: 0.14, blue: 0.17)
    static let pink = Color(red: 1.0, green: 0.165, blue: 0.502)
    static let lcd = Color(red: 0.93, green: 0.93, blue: 0.95)
    static let neonYellow = Color(red: 1.0, green: 0.9, blue: 0.2)
    static let neonGreen = Color(red: 0.45, green: 1.0, blue: 0.6)
}

extension View {
    /// ZZZ lettering: heavy, condensed, uppercase.
    func caps(_ size: CGFloat) -> some View {
        font(.system(size: size, weight: .black)).fontWidth(.condensed).textCase(.uppercase)
    }
}

/// A rectangle leaning to the right, the way ZZZ panels do.
struct Slant: Shape {
    var skew: CGFloat = 12
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX + skew, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - skew, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

/// Diagonal hazard stripes.
struct Hazard: View {
    var color = Ink.pink
    var body: some View {
        Canvas { context, size in
            let w: CGFloat = 10
            var x = -size.height
            while x < size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                p.addLine(to: CGPoint(x: x + size.height + w, y: 0))
                p.addLine(to: CGPoint(x: x + w, y: size.height))
                p.closeSubpath()
                context.fill(p, with: .color(color))
                x += w * 2
            }
        }
    }
}

/// Album art pressed as a CD: spins while playing and holds its angle while paused.
struct Disc: View {
    let art: URL?
    let spinning: Bool
    var size: CGFloat = 250
    @State private var spun = 0.0
    @State private var since: Date?

    var body: some View {
        TimelineView(.animation(paused: !spinning)) { context in
            let angle = spun + (since.map { context.date.timeIntervalSince($0) * 90 } ?? 0)
            ZStack {
                AsyncImage(url: art) { $0.resizable().scaledToFill() } placeholder: {
                    ZStack {
                        Ink.pink
                        Image(systemName: "music.note").font(.system(size: size * 0.2, weight: .black)).foregroundStyle(.black.opacity(0.5))
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                Circle().stroke(.white.opacity(0.35), lineWidth: 1).frame(width: size * 0.92, height: size * 0.92)
                Circle().fill(Ink.black).frame(width: size * 0.3, height: size * 0.3)
                Circle().stroke(.white, lineWidth: max(1, size * 0.012)).frame(width: size * 0.3, height: size * 0.3)
                Circle().stroke(.white.opacity(0.7), lineWidth: 1).frame(width: size * 0.18, height: size * 0.18)
            }
            .rotationEffect(.degrees(angle))
        }
        .frame(width: size, height: size)
        .onChange(of: spinning, initial: true) { _, on in
            if on { since = Date() } else if let s = since { spun += Date().timeIntervalSince(s) * 90; since = nil }
        }
    }
}

/// Square album art for lists.
struct Cover: View {
    let url: URL?
    var size: CGFloat = 64
    var body: some View {
        AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
            ZStack {
                Ink.panel
                Image(systemName: "opticaldisc.fill").foregroundStyle(Ink.pink)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
