import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: Session
    @State private var server = Session.defaultServer
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        ZStack {
            Ink.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Hazard().frame(height: 10)
                Text("Spin").caps(48).foregroundStyle(.white)
                Text("Sign in to your Jellyfin").caps(13).foregroundStyle(Ink.pink)
                field("Server", text: $server).keyboardType(.URL)
                field("User", text: $username)
                SecureField("Password", text: $password)
                    .padding(12).background(Ink.panel, in: Slant())
                if let error { Text(error).font(.footnote.weight(.semibold)).foregroundStyle(Ink.pink) }
                Button { Task { await signIn() } } label: {
                    Text(busy ? "…" : "Enter").caps(18)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Ink.pink, in: Slant()).foregroundStyle(.black)
                }
                .disabled(busy || username.isEmpty)
                Spacer()
            }
            .padding(24)
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(12).background(Ink.panel, in: Slant())
    }

    private func signIn() async {
        busy = true
        defer { busy = false }
        do {
            try await session.signIn(server: server, username: username, password: password)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
