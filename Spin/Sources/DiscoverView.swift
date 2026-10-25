import SwiftUI

/// Songs to explore, picked on the home server from what is played and loved in this library (spin-sources
/// /discover: each favourite's YouTube Music radio, ranked, nothing already here), each with why ("Because you like
/// Watson"). The plus downloads one through yubal, as Add music does; the arrow asks for a new list (the server
/// keeps one for six hours, and a new one takes about ten seconds).
struct DiscoverView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var picks: [Sources.Result]?
    @State private var seeds: [String] = []
    @State private var added: Set<String> = []
    @State private var error: String?
    @State private var loading = false
    private let yubal = Yubal()
    private let sources = Sources()

    var body: some View {
        ZStack {
            Ink.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Discover").caps(34).foregroundStyle(.white)
                        Spacer()
                        Button { Task { await load(fresh: true) } } label: {
                            Image(systemName: "arrow.clockwise").font(.headline).foregroundStyle(.white).frame(width: 44, height: 44)
                        }
                        .disabled(loading)
                        .accessibilityLabel("A new list")
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.headline).foregroundStyle(.white).frame(width: 44, height: 44)
                        }
                    }
                    Hazard().frame(height: 8)
                    Text(seeds.isEmpty ? "For you" : "From \(seeds.count) songs you love").caps(12).foregroundStyle(Ink.pink)
                    if loading { ProgressView().tint(Ink.pink).frame(maxWidth: .infinity) }
                    if let picks, picks.isEmpty, !loading {
                        Text("Nothing yet: play a few songs first").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(picks ?? []) { pick in
                        ResultRow(result: pick, added: added.contains(pick.url), owned: false) { Task { await add(pick.url) } }
                    }
                    if let error { Text(error).font(.callout).foregroundStyle(Ink.pink) }
                }
                .padding(16)
            }
        }
        .task { await load(fresh: false) }
    }

    private func load(fresh: Bool) async {
        guard let client = session.client else { return }
        loading = true
        defer { loading = false }
        do {
            let found = try await sources.discover(via: client, fresh: fresh)
            picks = found.results
            seeds = found.seeds
            error = nil
        } catch {
            picks = picks ?? []
            self.error = error.localizedDescription
        }
    }

    private func add(_ url: String) async {
        do {
            try await yubal.add(url)
            added.insert(url)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
