import Foundation
import Foundation
import PodFillCore

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0
func check(_ ok: Bool, _ note: String = "", line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("    FAIL (line \(line)) \(note)") }
}


/// Self-check (swift test is unusable on Command Line Tools only: neither Swift Testing's macro plugin nor XCTest ships there).
/// Run with `swift run PodFillSelfCheck`.
/// Fixtures in /fixtures are raw output captured from `spotdl 4.6.0 download ... --simple-tui --log-level INFO`.
private func fixture(_ name: String) throws -> [String] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/\(name)")
    return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
}

enum OutputParserTests {
    static func testSongStatusLines() {
        check(OutputParser.parse("Radiohead - Airbag: Searching for song") == .song(name: "Radiohead - Airbag", status: .searching))
        check(OutputParser.parse("Radiohead - Airbag: Getting audio meta") == .song(name: "Radiohead - Airbag", status: .searching))
        check(OutputParser.parse("Radiohead - Airbag: Downloading") == .song(name: "Radiohead - Airbag", status: .downloading))
        check(OutputParser.parse("Radiohead - Airbag: Embedding metadata") == .song(name: "Radiohead - Airbag", status: .tagging))
        check(OutputParser.parse("Radiohead - Airbag: Done") == .song(name: "Radiohead - Airbag", status: .done))
        check(OutputParser.parse("Radiohead - Fitter Happier: Skipped") == .song(name: "Radiohead - Fitter Happier", status: .alreadyHad))
    }

    static func testTitleContainingColonIsNotSplit() {
        check(OutputParser.parse("Artist - Part 1: The Start: Done") == .song(name: "Artist - Part 1: The Start", status: .done))
    }

    static func testFoundAndProgressLines() {
        check(OutputParser.parse("Found 12 songs in OK Computer (Album)") == .found(count: 12, listName: "OK Computer"))
        check(OutputParser.parse("3/12 complete") == .progress(done: 3, total: 12))
        check(OutputParser.parse("Found 50 songs in Today’s Top Hits (Playlist)") == .found(count: 50, listName: "Today’s Top Hits"))
    }

    static func testNoiseIsIgnored() {
        check(OutputParser.parse("Processing query: https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8") == .ignored)
        check(OutputParser.parse("Downloaded \"Radiohead - Airbag\": https://music.youtube.com/watch?v=jNY_wLukVW0") == .ignored)
        check(OutputParser.parse("Skipping Radiohead - Fitter Happier (file already exists) (duplicate)") == .ignored)
        check(OutputParser.parse("") == .ignored)
    }

    static func testFfmpegErrorFromRealRun() {
        // Real line from a failed run (empty {list-name} made the output path "/Artist - Title.mp3").
        let line = "FFmpegError: Failed to convert Rick Astley - Never Gonna Give You Up, you can find error here:"
        guard case let .error(kind, message) = OutputParser.parse(line) else { check(false, "not an error"); return }
        check(kind == "FFmpegError")
        check(OutputParser.song(mentionedIn: message, among: ["Rick Astley - Never Gonna Give You Up", "Other - Song"]) == "Rick Astley - Never Gonna Give You Up")
    }

    static func testLookupErrorFormat() {
        // Format taken from spotdl's source (logger.error("%s: %s", cls, msg)); not captured live.
        let line = "LookupError: No results found for song: Artist - Title"
        check(OutputParser.parse(line) == .error(kind: "LookupError", message: "No results found for song: Artist - Title"))
    }

    static func testRealThreeTrackAlbumRun() throws {
        var model = Replay()
        for l in try fixture("album-three-tracks.raw.txt") { model.feed(l) }
        check(model.statuses == [
            "Radiohead - Fitter Happier": .done,
            "Radiohead - No Surprises": .done,
            "Radiohead - Electioneering": .done,
        ])
        check(model.progress?.done == 3 && model.progress?.total == 3)
    }

    static func testRealRunWithSkippedAndPaddedLines() throws {
        // Captured with COLUMNS=1000, so every line is padded with trailing spaces.
        var model = Replay()
        for l in try fixture("album-skip-and-download.raw.txt") { model.feed(l) }
        check(model.total == 12)
        check(model.statuses["Radiohead - Fitter Happier"] == .alreadyHad)
        check(model.statuses["Radiohead - Airbag"] == .done)
        check(model.statuses["Radiohead - Let Down"] == .downloading)   // run was killed mid-download
    }

    static func testRealFfmpegFailureRun() throws {
        var model = Replay()
        for l in try fixture("track-ffmpeg-error.raw.txt") { model.feed(l) }
        check(model.errors.count == 1)
        check(model.progress?.done == 1)
    }
}

enum SpotifyURLTests {
    static func testParsesAllKindsAndStripsTracking() {
        let text = """
        https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8?si=abc123
        https://open.spotify.com/intl-fr/album/6dVIqQ8qmQ5GBnJ9shOYGE
        https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M, spotify:track:4PTG3Z6ehGkBFwjybzWkR8
        not a link
        """
        let (links, rejected) = SpotifyURL.parse(text)
        check(links.map(\.kind) == [.track, .album, .playlist])
        check(links[0].url == "https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8")
        check(rejected == ["not", "a", "link"])
    }

    static func testTracksNeverUseListNameTemplate() {
        let (links, _) = SpotifyURL.parse("https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8 https://open.spotify.com/album/6dVIqQ8qmQ5GBnJ9shOYGE")
        let jobs = Job.plan(for: links)
        check(jobs.count == 2)
        let album = jobs[0].arguments(ffmpeg: "/x/ffmpeg", destination: "/d")
        let track = jobs[1].arguments(ffmpeg: "/x/ffmpeg", destination: "/d")
        check(album.last == "/d/{list-name}/{artist} - {title}.{output-ext}")
        check(track.last == "/d/Singles/{artist} - {title}.{output-ext}")
    }
}

enum EngineTests {
    static let sample = AppPaths(dataDir: "/tmp/PodFill test é/data dir")

    static func testDataDirLayout() {
        let p = sample
        check(p.uv == "/tmp/PodFill test é/data dir/uv/uv")
        check(p.spotdl == "/tmp/PodFill test é/data dir/bin/spotdl")
        check(p.ffmpeg == "/tmp/PodFill test é/data dir/home/.spotdl/ffmpeg")
        check(p.deno == "/tmp/PodFill test é/data dir/home/.spotdl/deno")
        check(p.spotdlTemp == "/tmp/PodFill test é/data dir/home/.spotdl/temp")
        check(AppPaths.current(environment: [:]).dataDir == NSHomeDirectory() + "/Library/Application Support/PodFill")
        check(AppPaths.current(environment: ["PODFILL_DATA_DIR": "  "]).dataDir.hasSuffix("/Library/Application Support/PodFill"))
        check(AppPaths.current(environment: ["PODFILL_DATA_DIR": "/tmp/a b/../c"]).dataDir == "/tmp/c")
    }

    static func testChildEnvironmentIsolation() {
        let env = sample.childEnvironment(inherited: [
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": "/Users/you", "HTTPS_PROXY": "http://proxy:8080",
            "UV_INDEX_URL": "https://example.com/simple", "UV_TOOL_DIR": "/elsewhere", "VIRTUAL_ENV": "/venv",
            "PYTHONPATH": "/lib", "TMPDIR": "/var/tmp/",
        ])
        check(env["HOME"] == "/tmp/PodFill test é/data dir/home", "spotdl's ~/.spotdl goes inside the data dir")
        check(env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin", "no Homebrew tools picked up")
        check(env["HTTPS_PROXY"] == "http://proxy:8080" && env["TMPDIR"] == "/var/tmp/")
        check(env["UV_INDEX_URL"] == nil && env["VIRTUAL_ENV"] == nil && env["PYTHONPATH"] == nil)
        check(env["PYTHONIOENCODING"] == "utf-8" && env["PYTHONUTF8"] == "1" && env["PYTHONUNBUFFERED"] == "1")
        check(env["COLUMNS"] == "1000" && env["NO_COLOR"] == "1")
        check(env["UV_MANAGED_PYTHON"] == "1" && env["UV_NO_CONFIG"] == "1" && env["UV_PYTHON_INSTALL_BIN"] == "0")
        for key in ["UV_TOOL_DIR", "UV_TOOL_BIN_DIR", "UV_PYTHON_INSTALL_DIR", "UV_PYTHON_BIN_DIR", "UV_CACHE_DIR", "DENO_DIR"] {
            check(env[key]?.hasPrefix("/tmp/PodFill test é/data dir/") == true, key)
        }
    }

    static func testUvAssetPerArchitecture() {
        let arm = UvRelease.asset(for: .arm64), intel = UvRelease.asset(for: .x86_64)
        check(arm.name == "uv-aarch64-apple-darwin.tar.gz" && intel.name == "uv-x86_64-apple-darwin.tar.gz")
        check(arm.url.absoluteString == "https://github.com/astral-sh/uv/releases/download/0.13.9/uv-aarch64-apple-darwin.tar.gz")
        check(arm.checksumURL.absoluteString == arm.url.absoluteString + ".sha256")
        check([arm, intel].allSatisfy { $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit) })
        #if arch(arm64)
        check(UvRelease.machineArch() == .arm64)
        #endif
    }

    static func testChecksumFileParsing() {
        // The exact contents of uv-aarch64-apple-darwin.tar.gz.sha256 from the 0.13.9 release.
        let published = "5aeca67f2283f75235de40d0bd9c0a5bbc5fce23b6d48b3bf9fa1b2db08382ca  uv-aarch64-apple-darwin.tar.gz\n"
        check((try? UvRelease.parseChecksumFile(published)) == UvRelease.asset(for: .arm64).sha256)
        check((try? UvRelease.parseChecksumFile("<html>Not Found</html>")) == nil)
        check((try? UvRelease.parseChecksumFile("")) == nil)
    }

    static func testHashAndExtraction() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("podfill-check-\(UUID().uuidString) é").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/src/uv-aarch64-apple-darwin", withIntermediateDirectories: true)
        try "abc".write(toFile: dir + "/abc.txt", atomically: true, encoding: .utf8)
        check(try SetupService.sha256(ofFile: dir + "/abc.txt") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Same layout as the real macOS asset: uv-<target>/uv inside a .tar.gz.
        try "bin".write(toFile: dir + "/src/uv-aarch64-apple-darwin/uv", atomically: true, encoding: .utf8)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", dir + "/uv.tar.gz", "-C", dir + "/src", "uv-aarch64-apple-darwin"]
        try tar.run(); tar.waitUntilExit()
        try SetupService.extract(archive: dir + "/uv.tar.gz", to: dir + "/out")
        check((try? String(contentsOfFile: dir + "/out/uv-aarch64-apple-darwin/uv", encoding: .utf8)) == "bin")
        check((try? SetupService.extract(archive: dir + "/abc.txt", to: dir + "/bad")) == nil, "not an archive -> error")
    }

    static func testExactCommands() {
        let p = sample
        check(Commands.installSpotdl(p).arguments == ["tool", "install", "spotdl>=4.6,<5", "--python", "3.13"])
        check(Commands.installSpotdl(p).executable == p.uv)
        check(Commands.upgradeSpotdl(p).arguments == ["tool", "upgrade", "spotdl"])
        check(Commands.downloadFfmpeg(p) == ToolCommand(p.spotdl, ["--download-ffmpeg"], standardInput: "y\n"))
        check(Commands.downloadDeno(p).standardInput == "y\n")
        let track = Job.plan(for: SpotifyURL.parse("https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8").links)[0]
        let download = Commands.download(p, job: track, destination: "/Users/you/Music/iPod")
        check(download.executable == p.spotdl)
        check(download.arguments[download.arguments.firstIndex(of: "--ffmpeg")! + 1] == p.ffmpeg)
        check(download.arguments.last == "/Users/you/Music/iPod/Singles/{artist} - {title}.{output-ext}")
    }

    /// One uv pin for both apps: the Windows app's UvRelease.cs / AppPaths.cs must say the same.
    static func testPinsMatchWindowsApp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cs = try String(contentsOf: root.appendingPathComponent("windows/src/PodFill.Core/UvRelease.cs"), encoding: .utf8)
        let csPaths = try String(contentsOf: root.appendingPathComponent("windows/src/PodFill.Core/AppPaths.cs"), encoding: .utf8)
        check(cs.contains("public const string Version = \"\(UvRelease.version)\";"), "uv version differs from UvRelease.cs")
        for (asset, hash) in UvRelease.sha256 {
            check(cs.contains("[\"\(asset)\"] = \"\(hash)\""), "\(asset) hash differs from UvRelease.cs")
        }
        check(csPaths.contains("PythonVersion = \"\(Commands.pythonVersion)\""), "Python version differs from AppPaths.cs")
        check(csPaths.contains("SpotdlRequirement = \"\(Commands.spotdlRequirement)\""), "spotdl requirement differs from AppPaths.cs")
    }
}

/// Minimal stand-in for the app model, to replay captured output through the parser.
private struct Replay {
    var statuses: [String: SongStatus] = [:]
    var progress: (done: Int, total: Int)?
    var total: Int?
    var errors: [String] = []
    mutating func feed(_ line: String) {
        switch OutputParser.parse(line) {
        case .song(let n, let s): statuses[n] = s
        case .progress(let d, let t): progress = (d, t)
        case .found(let c, _): total = c
        case .error(let k, _): errors.append(k)
        case .ignored: break
        }
    }
}

// MARK: runner

// `PodFillSelfCheck --command <spotify-url>... <destination>` prints the exact spotdl invocation the app would run.
if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--command" {
    let dest = CommandLine.arguments.last!
    let links = SpotifyURL.parse(CommandLine.arguments[2..<(CommandLine.arguments.count - 1)].joined(separator: " ")).links
    let paths = AppPaths.current()
    let env = paths.childEnvironment().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    for job in Job.plan(for: links) {
        let command = Commands.download(paths, job: job, destination: dest)
        print((["/usr/bin/env", "-i"] + env + [command.executable] + command.arguments).map { "'\($0)'" }.joined(separator: " "))
    }
    exit(0)
}

// `PODFILL_DATA_DIR=<dir> PodFillSelfCheck --setup-smoke`: the real first-launch setup (the app's SetupService) in
// an isolated data dir, then Update downloader. No Spotify or YouTube queries. Fails if anything lands outside
// the data dir. The macOS CI job runs this.
if CommandLine.arguments.dropFirst().first == "--setup-smoke" {
    exit(SetupSmoke.run())
}

// `--download` / `--cancel` / `--update`: the app's DownloadModel, headless (see Harness.swift). Runs on the main actor.
if let mode = CommandLine.arguments.dropFirst().first, ["--download", "--cancel", "--update"].contains(mode) {
    let args = Array(CommandLine.arguments.dropFirst())
    Task { @MainActor in exit(await Harness.main(args)) }
    dispatchMain()
}
func run(_ name: String, _ body: () throws -> Void) {
    let before = failures
    do { try body() } catch { failures += 1; print("    ERROR \(error)") }
    print(failures == before ? "PASS \(name)" : "FAIL \(name)")
}
run("OutputParserTests.testSongStatusLines") { OutputParserTests.testSongStatusLines() }
run("OutputParserTests.testTitleContainingColonIsNotSplit") { OutputParserTests.testTitleContainingColonIsNotSplit() }
run("OutputParserTests.testFoundAndProgressLines") { OutputParserTests.testFoundAndProgressLines() }
run("OutputParserTests.testNoiseIsIgnored") { OutputParserTests.testNoiseIsIgnored() }
run("OutputParserTests.testFfmpegErrorFromRealRun") { OutputParserTests.testFfmpegErrorFromRealRun() }
run("OutputParserTests.testLookupErrorFormat") { OutputParserTests.testLookupErrorFormat() }
run("OutputParserTests.testRealThreeTrackAlbumRun") { try OutputParserTests.testRealThreeTrackAlbumRun() }
run("OutputParserTests.testRealRunWithSkippedAndPaddedLines") { try OutputParserTests.testRealRunWithSkippedAndPaddedLines() }
run("OutputParserTests.testRealFfmpegFailureRun") { try OutputParserTests.testRealFfmpegFailureRun() }
run("SpotifyURLTests.testParsesAllKindsAndStripsTracking") { SpotifyURLTests.testParsesAllKindsAndStripsTracking() }
run("SpotifyURLTests.testTracksNeverUseListNameTemplate") { SpotifyURLTests.testTracksNeverUseListNameTemplate() }
run("EngineTests.testDataDirLayout") { EngineTests.testDataDirLayout() }
run("EngineTests.testChildEnvironmentIsolation") { EngineTests.testChildEnvironmentIsolation() }
run("EngineTests.testUvAssetPerArchitecture") { EngineTests.testUvAssetPerArchitecture() }
run("EngineTests.testChecksumFileParsing") { EngineTests.testChecksumFileParsing() }
run("EngineTests.testHashAndExtraction") { try EngineTests.testHashAndExtraction() }
run("EngineTests.testExactCommands") { EngineTests.testExactCommands() }
run("EngineTests.testPinsMatchWindowsApp") { try EngineTests.testPinsMatchWindowsApp() }
// The smoke test's leak detector must notice a new folder and a file written into an existing one.
run("OutsideGuard detects writes") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("podfill-guard-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createDirectory(atPath: dir + "/existing", withIntermediateDirectories: true)
    let guarded = OutsideGuard(paths: [dir + "/existing", dir + "/.spotdl", dir + "/untouched"])
    check(guarded.changes().isEmpty)
    try FileManager.default.createDirectory(atPath: dir + "/.spotdl", withIntermediateDirectories: true)
    try "x".write(toFile: dir + "/existing/spotdl", atomically: false, encoding: .utf8)
    check(guarded.changes() == [dir + "/existing", dir + "/.spotdl"], "\(guarded.changes())")
}
// A spotdl "overwrite? (y/N)" prompt gets the canned answer, then EOF: never a hang.
run("ProcessRunner answers a prompt on stdin, then closes it") {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var lines: [String] = []
    nonisolated(unsafe) var status: Int32 = -99
    Task.detached {
        status = (try? await ProcessRunner().run(executable: "/bin/sh",
            arguments: ["-c", "printf 'Overwrite? (y/N): '; read x; echo \"got $x\"; read y || echo eof"],
            environment: ["PATH": "/bin:/usr/bin"], input: "y\n", onLine: { lines.append($0) })) ?? -1
        done.signal()
    }
    check(done.wait(timeout: .now() + 5) == .success, "no hang")
    check(status == 0 && lines.contains("Overwrite? (y/N): got y") && lines.contains("eof"), "\(lines)")
}
// Cancel must kill the whole tree: a shell with two sleeping grandchildren stands in for spotdl -> yt-dlp/ffmpeg.
run("ProcessRunner.terminateTree kills descendants") {
    let runner = ProcessRunner()
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var status: Int32 = 0
    Task {
        status = (try? await runner.run(executable: "/bin/sh", arguments: ["-c", "sleep 61 & sleep 62 & wait"],
                                        environment: ["PATH": "/bin:/usr/bin"], onLine: { _ in })) ?? -99
        done.signal()
    }
    Thread.sleep(forTimeInterval: 0.7)
    func sleepers() -> Int {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", "^sleep 6[12]$"]
        let o = Pipe(); p.standardOutput = o; try? p.run(); p.waitUntilExit()
        return String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").count
    }
    check(sleepers() == 2, "two sleep grandchildren running before cancel")
    runner.terminateTree()
    check(done.wait(timeout: .now() + 5) == .success, "runner returned after cancel")
    Thread.sleep(forTimeInterval: 0.3)
    check(sleepers() == 0, "no sleep processes left after cancel")
}

print("\n\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
