import PhotosUI
import SwiftUI

/// Rename a song, change its artist or album, or give it a cover from Photos. Changes go into the file itself.
struct EditSongView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    let track: Track
    let changed: () async -> Void
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var picked: PhotosPickerItem?
    @State private var cover: UIImage?
    @State private var busy = false
    @State private var error: String?

    init(track: Track, changed: @escaping () async -> Void) {
        self.track = track
        self.changed = changed
        _title = State(initialValue: track.name)
        _artist = State(initialValue: track.artist)
        _album = State(initialValue: track.album ?? "")
    }

    var body: some View {
        ZStack {
            Ink.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Edit song").caps(30).foregroundStyle(.white)
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.headline).foregroundStyle(.white).frame(width: 44, height: 44)
                        }
                    }
                    Hazard().frame(height: 8)
                    PhotosPicker(selection: $picked, matching: .images) {
                        ZStack(alignment: .bottomTrailing) {
                            if let cover {
                                Image(uiImage: cover).resizable().scaledToFill().frame(width: 160, height: 160).clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                Cover(url: session.client?.artwork(for: track, size: 400), size: 160)
                            }
                            Image(systemName: "photo.badge.plus").font(.title3).foregroundStyle(.black)
                                .padding(8).background(Ink.pink, in: Circle()).offset(x: 8, y: 8)
                        }
                    }
                    .accessibilityLabel("Choose album art")
                    field("Title", $title)
                    field("Artist", $artist)
                    field("Album", $album)
                    if let error { Text(error).font(.footnote.weight(.semibold)).foregroundStyle(Ink.pink) }
                    Button { Task { await save() } } label: {
                        Text(busy ? "Saving…" : "Save").caps(17)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Ink.pink, in: Slant()).foregroundStyle(.black)
                    }
                    .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(16)
            }
        }
        .onChange(of: picked) {
            Task {
                guard let data = try? await picked?.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
                cover = image
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).caps(11).foregroundStyle(.white.opacity(0.6))
            TextField(label, text: text).padding(12).background(Ink.panel, in: Slant())
        }
    }

    private func save() async {
        guard let client = session.client else { return }
        busy = true
        defer { busy = false }
        do {
            let sources = Sources()
            if title != track.name || artist != track.artist || album != (track.album ?? "") {
                try await sources.edit(track, title: title, artist: artist, album: album, via: client)
            }
            if let cover, let jpeg = squared(cover).jpegData(compressionQuality: 0.88) {
                try await sources.setArt(track, jpeg: jpeg, via: client)
            }
            await changed()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A centre square of at most 1200 points: covers are square, and Photos may hand over a 48-megapixel HEIC.
func squared(_ image: UIImage) -> UIImage {
    let side = min(image.size.width, image.size.height)
    let out = min(side, 1200)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: out, height: out), format: format).image { _ in
        let scale = out / side
        image.draw(in: CGRect(x: -(image.size.width - side) / 2 * scale, y: -(image.size.height - side) / 2 * scale,
                              width: image.size.width * scale, height: image.size.height * scale))
    }
}
