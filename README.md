# Spin

A personal Spotify: your own music, streamed from Jellyfin on the home server, in a Zenless-Zone-Zero-styled
CD-deck player (black deck, hot pink disc, vertical LCD, hazard stripes). iPhone, SwiftUI, iOS 17+.

## How it fits together

- **Music** lives in `/mnt/secondary/anime-server/data/media/music/<Artist>/<Album>/` on haruserver. Drop files
  there (mp3, m4a, flac, …; tags give title/artist/album/art). Jellyfin's **Music** library watches that folder;
  if something does not show up, Dashboard → Libraries → Scan.
- **Jellyfin** (the anime-server Docker stack) serves it. The phone reaches it over Tailscale at
  `https://haruserver.tail6da04d.ts.net:8920` (a `tailscale serve` route to 127.0.0.1:8096, tailnet only).
- **The app** signs in with the Jellyfin user (`toomii` + password), lists albums, plays with AVPlayer
  (direct play, or Jellyfin transcodes to AAC/HLS), keeps playing in the background with lock-screen controls.

## Adding music

The **+** in the library opens Add music: search YouTube Music or SoundCloud and tap + on a song, album or
playlist, or paste a link. The library is one song list, newest first.

- YouTube Music → [yubal](https://github.com/guillevc/yubal) (anime-server compose service `yubal`,
  127.0.0.1:8010, m4a), files tagged into `<Artist>/<Year> - <Album>/`.
- Search and SoundCloud → `~/spin-sources/server.py` (user service `spin-sources`, 127.0.0.1:8011):
  [ytmusicapi](https://github.com/sigma67/ytmusicapi) and SoundCloud search, [scdl](https://github.com/scdl-org/scdl)
  downloads, filed as `<Artist>/<Album>/` (a single becomes its own album).
- The phone reaches both at `https://haruserver.tail6da04d.ts.net:8930` (yubal) and `…:8930/sources`
  (`tailscale serve`, tailnet only; neither has a login).

## Code

- `Spin/Sources/Jellyfin.swift` — the client (auth, albums, tracks, stream and artwork URLs) and the saved session.
- `Spin/Sources/Player.swift` — AVPlayer, the current disc, Now Playing and remote commands.
- `Spin/Sources/Transport.swift` — the list logic and the LCD clock; tested by `scripts/test-transport.sh`.
- `Spin/Sources/PlayerView.swift`, `LibraryView.swift`, `LoginView.swift`, `Theme.swift` — the look.
- `project.yml` — XcodeGen spec; the `.xcodeproj` is generated on the runner.

## Building (same pipeline as haru-ios)

The workflow `.github/workflows/ios.yml` builds every push to `main` on GitHub's xcode-27 runner: the transport
test, then xcodegen, then xcodebuild. Unsigned until the App Store Connect secrets exist (an `.ipa` artifact);
signed and uploaded to TestFlight once they do.

1. App Store Connect → My Apps → **+ New App**, bundle ID `com.toomiiverse.spin` (if Apple registers a different
   identifier, change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`).
2. `scripts/arm-testflight.sh <AuthKey.p8> <key id> <issuer id> <team id>` sets the four repository secrets and
   starts a signed build.
