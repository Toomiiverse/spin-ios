import SwiftUI

@main
struct SpinApp: App {
    @StateObject private var session = Session()
    @StateObject private var player = Player()

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
