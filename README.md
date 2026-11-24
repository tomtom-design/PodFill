# PodFill

A small macOS app that wraps [spotDL](https://github.com/spotDL/spotify-downloader): paste Spotify playlist, album or
track links and get tagged MP3s (title, artist, album, cover art) for an offline iPod. spotDL reads the metadata from
Spotify, downloads the matching audio from YouTube Music (yt-dlp) and tags it with ffmpeg.

## Setup

```sh
brew install pipx ffmpeg-full         # ffmpeg is already installed here (keg-only ffmpeg-full is found automatically)
pipx install spotdl
pipx runpip spotdl install -U yt-dlp
brew install deno                      # only if yt-dlp warns about a missing JavaScript runtime
```

## Build

```sh
./build.sh          # -> dist/PodFill.app (ad-hoc signed; needs only the Command Line Tools)
open dist/PodFill.app
swift run PodFillSelfCheck   # parser + cancel self-check (swift test doesn't work on CLT-only machines)
```

## Use

1. Paste one or more Spotify links (one per line).
2. Pick the destination (default `~/Music/iPod`, remembered).
3. Download. Albums and playlists get their own folder, single tracks go in `Singles/`; files are `Artist - Title.mp3`.
4. Re-running a playlist only fetches songs that are new ("Already had it" for the rest).
5. When finished: **Show in Finder**, or **Add to Music** (opens the new MP3s in the Music app).

### Sync to the iPod
Add to Music (or drag the folder into the Music app), connect the iPod, select it in the Finder sidebar, choose
Music, and sync.

## Choices worth knowing

- `--bitrate auto`: YouTube audio is about 128-160 kbps. Forcing 192k/320k would only make bigger files with no
  quality gain, so the MP3 keeps the source bitrate.
- Tracks use a different output template than lists: with a track URL, spotDL's `{list-name}` is empty and the path
  becomes `/Artist - Title.mp3` (the filesystem root; the conversion fails).
- `--lyrics` with no providers: lyrics lookups are slow and rate-limited, and the iPod doesn't need them.
- spotDL silently strips leading dots from folder names, so avoid destination folders like `.something`.

## Troubleshooting

- **Downloads fail or nothing is found:** click **Update downloader** (runs `pipx upgrade spotdl` and upgrades yt-dlp).
  YouTube breaks yt-dlp every few months.
- **Spotify rate limit (HTTP 429 / "retry after"):** spotDL uses shared Spotify credentials. Wait, or create your own
  app at developer.spotify.com and pass `--client-id` / `--client-secret` (put them in `~/.spotdl/config.json`).
- **Missing tool message at launch:** run the command shown, then press Check again.
- The **Log** disclosure shows spotDL's raw output.
- Cancel stops spotDL and its yt-dlp/ffmpeg children and deletes the half-written files.

## Layout

- `Sources/PodFillCore`: `SpotifyURL` (link parsing), `Tools` (tool paths + child env), `SpotdlCommand` (args),
  `OutputParser`, `ProcessRunner` (streaming + process-tree kill).
- `Sources/PodFill`: SwiftUI app (`DownloadModel`, `ContentView`, `PodFillApp`).
- `Sources/PodFillSelfCheck`: tests against real captured output in `fixtures/`.
