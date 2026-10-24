import SwiftUI

/// One session and one player for the phone and the car screen alike.
@MainActor enum Shared {
    static let session = Session()
    static let player = Player()
}

@main
struct SpinApp: App {
    @StateObject private var session = Shared.session
    @StateObject private var player = Shared.player

    var body: some Scene {
        WindowGroup {
            Group {
                if session.client != nil { LibraryView() } else { LoginView() }
            }
            .environmentObject(session)
            .environmentObject(player)
            .preferredColorScheme(.dark)
        }
    }
}
