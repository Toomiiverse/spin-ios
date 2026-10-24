import SwiftUI

/// Paste a YouTube Music link; yubal downloads it into the library and Jellyfin picks it up.
struct AddView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var link = ""
    @State private var jobs: [Yubal.Job] = []
    @State private var error: String?
    @State private var busy = false
    private let yubal = Yubal()

    var body: some View {
        ZStack {
            Ink.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Add music").caps(34).foregroundStyle(.white)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).foregroundStyle(.white).frame(width: 44, height: 44)
                    }
                }
                Hazard().frame(height: 8)
                Text("YouTube Music link: a song, album or playlist").caps(12).foregroundStyle(Ink.pink)
                HStack(spacing: 8) {
                    TextField("music.youtube.com/…", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .padding(12).background(Ink.panel, in: Slant())
                    Button { link = UIPasteboard.general.string ?? link } label: {
                        Image(systemName: "doc.on.clipboard").foregroundStyle(.white).frame(width: 44, height: 44)
                    }
                }
                Button { Task { await add() } } label: {
                    Text(busy ? "…" : "Download to library").caps(17)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Ink.pink, in: Slant()).foregroundStyle(.black)
                }
                .disabled(busy || !Yubal.isLink(link))
                Button { openURL(URL(string: "https://music.youtube.com/")!) } label: {
                    Label("Find something in YouTube Music, then Share → Copy link", systemImage: "magnifyingglass")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                }
                if let error { Text(error).font(.footnote.weight(.semibold)).foregroundStyle(Ink.pink) }
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(jobs) { JobRow(job: $0) }
                    }
                }
            }
            .padding(16)
        }
        .task {
            if let clip = UIPasteboard.general.string, Yubal.isLink(clip) { link = clip }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func add() async {
        busy = true
        defer { busy = false }
        do {
            try await yubal.add(link)
            link = ""
            error = nil
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refresh() async {
        do {
            jobs = try await yubal.jobs()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct JobRow: View {
    let job: Yubal.Job

    var body: some View {
        HStack(spacing: 12) {
            Cover(url: job.contentInfo?.thumbnailUrl.flatMap(URL.init(string:)), size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.contentInfo?.title ?? job.url).caps(15).foregroundStyle(.white).lineLimit(1)
                Text(job.contentInfo?.artist ?? "").font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                if job.finished {
                    Text(job.label).caps(11).foregroundStyle(job.status == "completed" ? Ink.neonGreen : Ink.pink)
                } else {
                    ProgressView(value: min(max(job.progress, 0), 100), total: 100).tint(Ink.pink)
                    Text(job.label).caps(11).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(10)
        .background(Ink.deck, in: RoundedRectangle(cornerRadius: 10))
    }
}
