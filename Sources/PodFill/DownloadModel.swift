import AppKit
import Foundation
import Observation
import PodFillCore

struct SongRow: Identifiable, Equatable {
    let id = UUID()
    let name: String
    var status: SongStatus
}

@MainActor
@Observable
final class DownloadModel {
    // Inputs
    var urlText = ""
    var destination: String = UserDefaults.standard.string(forKey: "destinationPath")
        ?? NSHomeDirectory() + "/Music/iPod" {
        didSet { UserDefaults.standard.set(destination, forKey: "destinationPath") }
    }

    // State
    var tools = Tools.locate()
    var songs: [SongRow] = []
    var overallDone = 0
    var overallTotal = 0
    var log = ""
    var notice: String?          // problem or hint shown above the progress
    var isRunning = false
    var isUpdating = false
    var finished = false
    var showLog = false
    var newFiles: [URL] = []

    private var runner: ProcessRunner?
    private var cancelled = false
    private var startedAt = Date()

    var parsedLinks: [SpotifyLink] { SpotifyURL.parse(urlText).links }
    var canDownload: Bool { !parsedLinks.isEmpty && tools.problems.isEmpty && !isRunning && !isUpdating }
    var isBusy: Bool { isRunning || isUpdating }

    var destinationURL: URL { URL(fileURLWithPath: destination) }

    func recheckTools() { tools = Tools.locate() }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = destinationURL.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { destination = url.path }
    }

    // MARK: Download

    func start() {
        let (links, rejected) = SpotifyURL.parse(urlText)
        guard !links.isEmpty, let spotdl = tools.spotdl, let ffmpeg = tools.ffmpeg else { return }
        songs = []; overallDone = 0; overallTotal = 0; log = ""; newFiles = []
        notice = rejected.isEmpty ? nil : "Skipped, not a Spotify track/album/playlist link: \(rejected.joined(separator: ", "))"
        isRunning = true; finished = false; cancelled = false
        startedAt = Date()
        let dest = destination
        let jobs = Job.plan(for: links)

        Task {
            var base = 0   // songs finished in earlier jobs
            for job in jobs where !cancelled {
                let args = job.arguments(ffmpeg: ffmpeg, destination: dest)
                appendLog("$ spotdl \(args.joined(separator: " "))\n")
                let jobSongsStart = songs.count
                var jobTotal = 0
                let status = await run(spotdl, args) { [self] event in
                    handle(event, jobSongsStart: jobSongsStart, base: base, jobTotal: &jobTotal)
                }
                if status != 0 && !cancelled && !songs[jobSongsStart...].contains(where: { $0.status.isFinished }) {
                    notice = "spotdl stopped with exit code \(status) before downloading anything. See the log."
                }
                base += jobTotal
                // Anything still marked in-progress when the process ended did not finish.
                for i in songs.indices where i >= jobSongsStart && !songs[i].status.isFinished {
                    songs[i].status = .failed(cancelled ? "Cancelled" : "Did not finish")
                }
            }
            if cancelled { removePartialFiles() }
            collectNewFiles()
            isRunning = false
            finished = true
            runner = nil
        }
    }

    func cancel() {
        cancelled = true
        runner?.terminateTree()
        appendLog("-- cancelled --\n")
    }

    private var lastJobSongNames: [String] = []

    private func handle(_ event: OutputEvent, jobSongsStart: Int, base: Int, jobTotal: inout Int) {
        switch event {
        case .found(let count, _):
            jobTotal = count
            overallTotal = max(overallTotal, base + count)
        case .progress(let done, let total):
            jobTotal = total
            overallTotal = max(overallTotal, base + total)
            overallDone = base + done
        case .song(let name, let status):
            if let i = songs[jobSongsStart...].firstIndex(where: { $0.name == name }) {
                // Never move a song backwards (e.g. a late "Searching" after "Done").
                if !songs[i].status.isFinished { songs[i].status = status }
            } else {
                songs.append(SongRow(name: name, status: status))
            }
            // Track URLs print no "Found N songs" line, so count songs as they appear.
            if jobTotal == 0 { overallTotal = max(overallTotal, base + songs.count - jobSongsStart) }
        case .error(let kind, let message):
            let names = songs[jobSongsStart...].filter { !$0.status.isFinished }.map(\.name)
            let reason = OutputParser.reason(kind: kind, message: message)
            if let name = OutputParser.song(mentionedIn: message, among: names),
               let i = songs[jobSongsStart...].firstIndex(where: { $0.name == name }) {
                songs[i].status = .failed(reason)
            } else {
                notice = reason
            }
        case .ignored:
            break
        }
    }

    /// Runs one process, forwarding lines to the log and the parser on the main actor.
    private func run(_ exe: String, _ args: [String], onEvent: @escaping @MainActor (OutputEvent) -> Void) async -> Int32 {
        let r = ProcessRunner()
        runner = r
        do {
            return try await r.run(executable: exe, arguments: args, environment: Tools.childEnvironment()) { line in
                Task { @MainActor in
                    self.appendLog(line + "\n")
                    self.hint(for: line)
                    onEvent(OutputParser.parse(line))
                }
            }
        } catch {
            appendLog("Could not start \(exe): \(error.localizedDescription)\n")
            notice = "Could not start \(exe): \(error.localizedDescription)"
            return -1
        }
    }

    private func hint(for line: String) {
        let l = line.lowercased()
        if l.contains("429") || l.contains("retry after") || l.contains("rate limit") {
            notice = "Spotify is rate-limiting spotdl's shared credentials. Wait a while, or use your own Spotify developer client ID (see README)."
        } else if l.contains("javascript runtime") || l.contains("deno") && l.contains("warn") {
            notice = "yt-dlp wants a JavaScript runtime. Run: brew install deno"
        }
    }

    // MARK: Files

    /// MP3s written during this run (older, skipped files keep their old modification date).
    private func collectNewFiles() {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: destinationURL, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = startedAt.addingTimeInterval(-1)
        newFiles = (e.allObjects as? [URL] ?? []).filter {
            $0.pathExtension.lowercased() == "mp3" &&
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >= cutoff
        }.sorted { $0.path < $1.path }
    }

    /// Killing ffmpeg mid-write leaves a truncated MP3 that spotdl would later skip as "already exists".
    /// Delete new files whose name matches a song that was still in progress when we cancelled.
    private func removePartialFiles() {
        collectNewFiles()
        let norm: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        let unfinished = Set(songs.filter { $0.status == .failed("Cancelled") }.map { norm($0.name) })
        for url in newFiles where unfinished.contains(norm(url.deletingPathExtension().lastPathComponent)) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func showInFinder() {
        if newFiles.isEmpty {
            NSWorkspace.shared.open(destinationURL)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(newFiles)
        }
    }

    func addToMusic() {
        guard !newFiles.isEmpty else { return }
        let music = URL(fileURLWithPath: "/System/Applications/Music.app")
        NSWorkspace.shared.open(newFiles, withApplicationAt: music, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Update downloader

    func updateDownloader() {
        guard let pipx = tools.pipx else {
            notice = "pipx was not found. Install it with: brew install pipx"
            return
        }
        isUpdating = true
        notice = nil
        Task {
            appendLog("\n== Update downloader ==\n")
            for args in [["upgrade", "spotdl"], ["runpip", "spotdl", "install", "-U", "yt-dlp"]] {
                appendLog("$ pipx \(args.joined(separator: " "))\n")
                _ = await run(pipx, args) { _ in }
            }
            appendLog("== Update finished ==\n")
            recheckTools()
            isUpdating = false
            runner = nil
        }
    }

    private func appendLog(_ s: String) { log += s }
}
