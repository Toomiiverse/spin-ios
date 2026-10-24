import Foundation

/// The part of playback that needs no AVPlayer: where we are in the disc and the LCD clock.
struct Transport: Equatable {
    enum Repeat: Equatable { case off, all, one }

    var count: Int
    var index = 0
    var time: Double = 0
    var repeatMode = Repeat.off

    /// A tap on next wraps around like a CD player.
    mutating func skipForward() {
        guard count > 0 else { return }
        index = (index + 1) % count
        time = 0
    }

    /// Back restarts the track once it is under way, otherwise goes to the previous one.
    mutating func skipBack() {
        guard count > 0 else { return }
        if time <= 3 && count > 1 { index = (index - 1 + count) % count }
        time = 0
    }

    /// A track ran out: true when there is a track to load (the same one on repeat-one), false when the disc is over.
    mutating func ended() -> Bool {
        guard count > 0 else { return false }
        time = 0
        switch repeatMode {
        case .one: return true
        case .all: index = (index + 1) % count; return true
        case .off:
            guard index + 1 < count else { return false }
            index += 1
            return true
        }
    }

    /// Off, all, one, off: the order Spotify and Apple Music cycle in.
    mutating func cycleRepeat() {
        repeatMode = repeatMode == .off ? .all : repeatMode == .all ? .one : .off
    }
}

/// mm:ss for the LCD; anything odd shows as 00:00.
func clock(_ seconds: Double) -> String {
    let t = seconds.isFinite ? max(0, Int(seconds)) : 0
    return String(format: "%02d:%02d", t / 60, t % 60)
}

/// The list shuffled with the item at `first` moved to the front, so the playing song keeps playing.
func shuffledKeeping<T>(_ items: [T], first: Int) -> [T] {
    guard items.indices.contains(first) else { return items.shuffled() }
    var rest = items
    let head = rest.remove(at: first)
    return [head] + rest.shuffled()
}

/// The index letter for a title: A–Z, or # for digits and everything else.
func letter(_ title: String) -> String {
    guard let first = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).first,
          first.isASCII, first.isLetter else { return "#" }
    return String(first).uppercased()
}
