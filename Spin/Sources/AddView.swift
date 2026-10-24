import SwiftUI

/// Search YouTube Music or SoundCloud, or paste a link; the server downloads it into the library.
/// YouTube Music goes to yubal, SoundCloud to scdl; both queues show together below.
struct AddView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var source = Sources.Source.youtube
    @State private var query = ""
    @State private var results: [Sources.Result] = []
    @State private var added: Set<String> = []
    @State private var link = ""
    @State private var jobs: [Yubal.Job] = []
    @State private var error: String?
    @State private var searching = false
    private let yubal = Yubal()
    private let sources = Sources()

    var body: some View {
        ZStack {
            Ink.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Add music").caps(34).foregroundStyle(.white)
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.headline).foregroundStyle(.white).frame(width: 44, height: 44)
                        }
                    }
                    Hazard().frame(height: 8)
                    Picker("Source", selection: $source) {
                        ForEach(Sources.Source.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: source) { results = []; if !query.isEmpty { Task { await search() } } }
                    TextField("Search \(source.title)", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        .onSubmit { Task { await search() } }
                        .padding(12).background(Ink.panel, in: Slant())
                    if searching { ProgressView().tint(Ink.pink).frame(maxWidth: .infinity) }
                    ForEach(results) { result in
                        ResultRow(result: result, added: added.contains(result.url)) { Task { await add(result.url) } }
                    }
                    Text("Or paste a YouTube Music or SoundCloud link").caps(12).foregroundStyle(Ink.pink).padding(.top, 6)
                    HStack(spacing: 8) {
                        TextField("music.youtube.com/… or soundcloud.com/…", text: $link)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .padding(12).background(Ink.panel, in: Slant())
                        Button { link = UIPasteboard.general.string ?? link } label: {
                            Image(systemName: "doc.on.clipboard").foregroundStyle(.white).frame(width: 44, height: 44)
                        }
                        Button { Task { if await add(link) { link = "" } } } label: {
                            Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Ink.pink).frame(width: 44, height: 44)
                        }
                        .disabled(!Yubal.isLink(link) && !Sources.isSoundCloud(link))
                    }
                    if let error { Text(error).font(.footnote.weight(.semibold)).foregroundStyle(Ink.pink) }
                    if !jobs.isEmpty {
                        Text("Downloads").caps(12).foregroundStyle(.white.opacity(0.6)).padding(.top, 6)
                        ForEach(jobs) { JobRow(job: $0) }
                    }
                }
                .padding(16)
            }
        }
        .task {
            if let clip = UIPasteboard.general.string, Yubal.isLink(clip) || Sources.isSoundCloud(clip) { link = clip }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            results = try await sources.search(q, in: source)
            error = results.isEmpty ? "Nothing found." : nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// SoundCloud links go to scdl, everything else to yubal.
    @discardableResult
    private func add(_ url: String) async -> Bool {
        do {
            if Sources.isSoundCloud(url) { try await sources.add(url) } else { try await yubal.add(url) }
            added.insert(url)
            error = nil
            await refresh()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func refresh() async {
        // Either server being down should not hide the other's queue.
        async let fromYouTube = try? yubal.jobs()
        async let fromSoundCloud = try? sources.jobs()
        let (yt, sc) = await (fromYouTube, fromSoundCloud)
        if yt == nil && sc == nil { error = error ?? "The downloaders are not reachable. Is Tailscale on?" }
        jobs = ((yt ?? []) + (sc ?? [])).sorted { !$0.finished && $1.finished }
    }
}

struct ResultRow: View {
    let result: Sources.Result
    let added: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Cover(url: result.thumbnail.flatMap(URL.init(string:)), size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.title).font(.system(size: 15, weight: .heavy)).foregroundStyle(.white).lineLimit(1)
                Text([result.artist, result.detail, result.duration].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                if result.kind == "album" || result.kind == "playlist" {
                    Text(result.kind).caps(10).foregroundStyle(Ink.pink)
                }
            }
            Spacer()
            Button(action: action) {
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.title2).foregroundStyle(added ? Ink.neonGreen : Ink.pink).frame(width: 44, height: 44)
            }
            .disabled(added)
            .accessibilityLabel(added ? "Added" : "Download \(result.title)")
        }
        .padding(8)
        .background(Ink.deck, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct JobRow: View {
    let job: Yubal.Job

    var body: some View {
        HStack(spacing: 12) {
            Cover(url: job.contentInfo?.thumbnailUrl.flatMap(URL.init(string:)), size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.contentInfo?.title ?? job.url).caps(14).foregroundStyle(.white).lineLimit(1)
                Text(job.contentInfo?.artist ?? "").font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                if job.finished {
                    Text(job.label).caps(11).foregroundStyle(job.status == "completed" ? Ink.neonGreen : Ink.pink)
                } else {
                    ProgressView(value: min(max(job.progress, 0), 100), total: 100).tint(Ink.pink)
                    Text(job.label).caps(11).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(8)
        .background(Ink.deck, in: RoundedRectangle(cornerRadius: 10))
    }
}
