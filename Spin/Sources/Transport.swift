import Foundation

/// The part of playback that needs no AVPlayer: where we are in the disc and the LCD clock.
struct Transport: Equatable {
    var count: Int
    var index = 0
    var time: Double = 0

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

    /// A track ran out: true when there is another one to load, false when the disc is over.
    mutating func ended() -> Bool {
        guard index + 1 < count else { return false }
        index += 1
        time = 0
        return true
    }
}

/// mm:ss for the LCD; anything odd shows as 00:00.
func clock(_ seconds: Double) -> String {
    let t = seconds.isFinite ? max(0, Int(seconds)) : 0
    return String(format: "%02d:%02d", t / 60, t % 60)
}
