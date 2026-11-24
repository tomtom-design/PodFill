# PodFill

A small macOS app that wraps [spotDL](https://github.com/spotDL/spotify-downloader): paste Spotify playlist, album or
track links and get tagged MP3s (title, artist, album, cover art) for an offline iPod. spotDL reads the metadata from
Spotify, downloads the matching audio from YouTube Music (yt-dlp) and tags it with ffmpeg.

PodFill sets itself up: no Homebrew, pipx or terminal needed.

## Install from Releases

Download `PodFill-macOS.zip` from the [Releases](https://github.com/tomtom-design/PodFill/releases) page, unzip it
and move `PodFill.app` to Applications. It is signed with a Developer ID and notarized by Apple, so it opens like any
other downloaded app. It runs on Apple Silicon and Intel Macs with macOS 14 or later.

On first launch, click **Set up** (one time, needs internet, a few minutes). PodFill downloads its own private engine
(spotDL, Python, ffmpeg and Deno, about 450 MB) into `~/Library/Application Support/PodFill`. It never touches a
spotDL, Python or ffmpeg you may have installed yourself.

**Windows:** download `PodFill-Windows.zip` from the same page. It sets itself up the same way;
[windows/README.txt](windows/README.txt) covers setup, syncing the iPod with iTunes or Apple Devices, and uninstalling.

## Use

1. Paste one or more Spotify links (one per line).
2. Pick the destination (default `~/Music/iPod`, remembered).
3. Download. Albums and playlists get their own folder, single tracks go in `Singles/`; files are `Artist - Title.mp3`.
4. Re-running a playlist only fetches songs that are new ("Already had it" for the rest).
5. When finished: **Show in Finder**, or **Add to Music** (opens the new MP3s in the Music app).

### Sync to the iPod
Add to Music (or drag the folder into the Music app), connect the iPod, select it in the Finder sidebar, choose
Music, and sync.

## Uninstall

1. Quit PodFill and move `PodFill.app` to the Trash.
2. In Finder choose Go > Go to Folder, enter `~/Library/Application Support/PodFill` and move that folder to the Trash.
   That is the whole engine.

Your music in `~/Music/iPod` stays. PodFill also keeps its window size and chosen folder in
`~/Library/Preferences/design.tomtom.podfill.plist`, which you can delete too.

## Troubleshooting

- **Downloads fail or nothing is found:** click **Update downloader**. It runs `uv tool upgrade spotdl`, which also
  fetches the latest yt-dlp. YouTube breaks yt-dlp every few months.
- **Spotify rate limit (HTTP 429 / "retry after"):** spotDL uses shared Spotify credentials. Wait, or create your own
  app at developer.spotify.com and put its `client_id` / `client_secret` in
  `~/Library/Application Support/PodFill/home/.spotdl/config.json`.
- **Something in the engine is broken or missing:** choose PodFill > **Run Setup Again…**. It repairs only what is
  missing and skips the rest.
- The **Log** disclosure shows spotDL's raw output.
- Cancel stops spotDL and its yt-dlp/ffmpeg children and deletes the half-written files.

## Choices worth knowing

- **Private engine:** a pinned [uv](https://github.com/astral-sh/uv) release (checked against its published sha256
  and the hash built into the app) installs `spotdl>=4.6,<5` on uv's own Python 3.13. ffmpeg and Deno come from
  spotDL's own downloaders (`--download-ffmpeg` gets a native arm64 or x86_64 build). Child processes get `HOME` set to
  the data dir's `home/` folder, so spotDL's `~/.spotdl` lives inside the data dir. The Windows app does the same; the
  self-check fails if the two apps' uv pins differ.
- `--bitrate auto`: YouTube audio is about 128-160 kbps. Forcing 192k/320k would only make bigger files with no
  quality gain, so the MP3 keeps the source bitrate.
- Tracks use a different output template than lists: with a track URL, spotDL's `{list-name}` is empty and the path
  becomes `/Artist - Title.mp3` (the filesystem root; the conversion fails).
- `--lyrics` with no providers: lyrics lookups are slow and rate-limited, and the iPod doesn't need them.
- spotDL silently strips leading dots from folder names, so avoid destination folders like `.something`.

## Build from source

```sh
./build.sh                    # -> dist/PodFill.app for this Mac (ad-hoc signed; needs only the Command Line Tools)
./build.sh --universal        # same, Apple Silicon + Intel
open dist/PodFill.app
swift run PodFillSelfCheck    # parser, engine, cancel self-check (swift test doesn't work on CLT-only machines)
PODFILL_DATA_DIR=/tmp/podfill-test swift run PodFillSelfCheck --setup-smoke   # real setup in a throwaway folder
```

`PODFILL_DATA_DIR` points the app (and the self-check) at another data dir, so tests never touch the real one.
With it set, `PodFillSelfCheck --download|--cancel --dest <folder> <url>` and `--update` drive the app's
`DownloadModel` without the window.

## Making a release

1. Tag and push: `git tag v1.0.0 && git push origin v1.0.0`. CI ([release.yml](.github/workflows/release.yml)) builds
   `PodFill-Windows.zip` on Windows and creates the GitHub Release with it.
2. On the release Mac, with that tag checked out and a clean working tree: `./release-mac.sh v1.0.0`. It builds a
   universal app, signs it with the Developer ID Application identity (hardened runtime), notarizes and staples it,
   and attaches `PodFill-macOS.zip` to the same release (creating the release if CI hasn't yet).

One-time setup for step 2: a Developer ID Application certificate in the keychain, notary credentials saved with
`xcrun notarytool store-credentials PodFill --apple-id <apple-id> --team-id <team-id>`, and `gh auth login`.

## Layout

- `Sources/PodFillCore`: `AppPaths` (data dir, child environment, exact commands), `UvRelease` (uv pin),
  `Setup` (`SetupService`, `CommandRunner`), `DownloadModel` (the app's state and actions), `SpotifyURL`,
  `SpotdlCommand`, `OutputParser`, `ProcessRunner` (streaming + process-tree kill).
- `Sources/PodFill`: SwiftUI app (`ContentView`, `PodFillApp`, and the Finder/Music/folder-picker actions).
- `Sources/PodFillSelfCheck`: tests against real captured output in `fixtures/`, the setup smoke test and the headless
  harness.
- `windows/`: the Windows app (C#/.NET + Avalonia), same engine design.
