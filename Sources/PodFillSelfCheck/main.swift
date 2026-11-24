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
    let tools = Tools.locate()
    for job in Job.plan(for: links) {
        let args = job.arguments(ffmpeg: tools.ffmpeg ?? "ffmpeg", destination: dest)
        let env = Tools.childEnvironment().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        print((["/usr/bin/env", "-i"] + env + [tools.spotdl ?? "spotdl"] + args).map { "'\($0)'" }.joined(separator: " "))
    }
    exit(0)
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
