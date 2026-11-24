import Foundation
import Observation

public struct SongRow: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let name: String
    public var status: SongStatus
}

/// The app's state and actions, without AppKit: the SwiftUI window binds to it (the app target adds the Finder,
/// Music and folder-picker actions), and `PodFillSelfCheck --download/--cancel` drives the very same code headless.
@MainActor
@Observable
public final class DownloadModel {
    // Inputs
    public var urlText = ""
    public var destination: String = UserDefaults.standard.string(forKey: "destinationPath")
        ?? NSHomeDirectory() + "/Music/iPod" {
        didSet { UserDefaults.standard.set(destination, forKey: "destinationPath") }
    }

    // Engine: everything lives in the app's private data dir (see AppPaths).
    public let paths: AppPaths
    @ObservationIgnored private let setup: SetupService
    @ObservationIgnored private let commands: CommandRunner

    // State
    public private(set) var songs: [SongRow] = []
    public private(set) var overallDone = 0
    public private(set) var overallTotal = 0
    public private(set) var log = ""
    public private(set) var notice: String?          // problem or hint shown above the progress
    public private(set) var info: String?            // neutral status (setup finished, downloader updated)
    public private(set) var isRunning = false
    public private(set) var isUpdating = false
    public private(set) var isSettingUp = false
    public private(set) var needsSetup: Bool
    public private(set) var setupStep = ""
    public private(set) var setupPercent: Double?    // nil: indeterminate
    public private(set) var finished = false
    public var showLog = false
    public private(set) var newFiles: [URL] = []
    /// The download, update or setup in flight (headless callers await it).
    @ObservationIgnored public private(set) var currentWork: Task<Void, Never>?

    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var startedAt = Date()

    public init(paths: AppPaths = .current()) {
        self.paths = paths
        setup = SetupService(paths: paths)
        commands = CommandRunner(paths: paths)
        needsSetup = !setup.isReady
    }

    public var parsedLinks: [SpotifyLink] { SpotifyURL.parse(urlText).links }
    public var canDownload: Bool { !parsedLinks.isEmpty && !needsSetup && !isBusy }
    public var isBusy: Bool { isRunning || isUpdating || isSettingUp }

    public var destinationURL: URL { URL(fileURLWithPath: destination) }

    // MARK: Download

    public func start() {
        let (links, rejected) = SpotifyURL.parse(urlText)
        guard !links.isEmpty, !needsSetup, !isBusy else { return }
        songs = []; overallDone = 0; overallTotal = 0; log = ""; newFiles = []; info = nil
        notice = rejected.isEmpty ? nil : "Skipped, not a Spotify track/album/playlist link: \(rejected.joined(separator: ", "))"
        isRunning = true; finished = false; cancelled = false
        startedAt = Date()
        let dest = destination
        let jobs = Job.plan(for: links)

        currentWork = Task {
            var base = 0   // songs finished in earlier jobs
            for job in jobs where !cancelled {
                let command = Commands.download(paths, job: job, destination: dest)
                appendLog("$ spotdl \(command.arguments.joined(separator: " "))\n")
                let jobSongsStart = songs.count
                var jobTotal = 0
                let status = await run(command) { [self] line in
                    handle(OutputParser.parse(line), jobSongsStart: jobSongsStart, base: base, jobTotal: &jobTotal)
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
        }
    }

    public func cancel() {
        cancelled = true
        commands.killCurrent()
        appendLog("-- cancelled --\n")
    }

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

    /// Runs one command; each output line goes to the log, the hints and `onLine`, in order, on the main actor.
    private func run(_ command: ToolCommand, onLine: @escaping @MainActor (String) -> Void) async -> Int32 {
        let lines = AsyncStream<String>.makeStream()
        let consumer = Task { @MainActor in
            for await line in lines.stream {
                appendLog(line + "\n")
                hint(for: line)
                onLine(line)
            }
        }
        defer { lines.continuation.finish() }
        do {
            let status = try await commands.run(command) { lines.continuation.yield($0) }
            lines.continuation.finish()
            await consumer.value
            return status
        } catch {
            lines.continuation.finish()
            await consumer.value
            let what = (command.executable as NSString).lastPathComponent
            appendLog("Could not start \(what): \(error.localizedDescription)\n")
            notice = "Could not start \(what): \(error.localizedDescription). Choose PodFill > Run Setup Again to repair."
            return -1
        }
    }

    private func hint(for line: String) {
        let l = line.lowercased()
        if l.contains("429") || l.contains("retry after") || l.contains("rate limit") {
            notice = "Spotify is rate-limiting spotdl's shared credentials. Wait a while, or use your own Spotify developer client ID (see README)."
        } else if l.contains("javascript runtime") || l.contains("deno") && l.contains("warn") {
            notice = "The YouTube downloader wants its JavaScript runtime (Deno). Choose PodFill > Run Setup Again to repair it."
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
    /// Delete new files whose name matches a song that was still in progress when we cancelled, and empty
    /// spotdl's private temp folder (half-downloaded audio).
    private func removePartialFiles() {
        collectNewFiles()
        let norm: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        let unfinished = Set(songs.filter { $0.status == .failed("Cancelled") }.map { norm($0.name) })
        for url in newFiles where unfinished.contains(norm(url.deletingPathExtension().lastPathComponent)) {
            try? FileManager.default.removeItem(at: url)
            appendLog("Removed unfinished file: \(url.path)\n")
        }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: paths.spotdlTemp)) ?? [] {
            try? fm.removeItem(atPath: paths.spotdlTemp + "/" + name)
        }
    }


    // MARK: Update downloader

    public func updateDownloader() {
        guard !isBusy, !needsSetup else { return }
        isUpdating = true
        notice = nil
        info = nil
        currentWork = Task {
            appendLog("\n== Update downloader ==\n")
            let command = Commands.upgradeSpotdl(paths)
            appendLog("$ \(command.display)\n")
            var updated: [String] = []
            let status = await run(command) { line in
                // uv prints " + yt-dlp==2026.11.23" for every package it upgraded.
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("+ "), let eq = t.range(of: "==") {
                    updated.append("\(t.dropFirst(2)[..<eq.lowerBound]) \(t[eq.upperBound...])")
                }
            }
            appendLog("== Update finished ==\n")
            if status != 0 {
                notice = "Update failed (exit code \(status)). See the log."
            } else {
                info = updated.isEmpty ? "The downloader is up to date." : "Updated \(updated.joined(separator: ", "))."
            }
            needsSetup = !setup.isReady
            isUpdating = false
        }
    }

    // MARK: Set up

    /// The one-time setup (also "Run Setup Again" to repair): downloads uv, spotdl + Python, ffmpeg and Deno.
    public func setUp() {
        guard !isBusy else { return }
        isSettingUp = true
        notice = nil
        info = nil
        showLog = true
        setupStep = ""
        setupPercent = nil
        currentWork = Task {
            appendLog("== Set up ==\n")
            // Log lines and progress arrive from background threads; one stream keeps them in order.
            enum Update: Sendable { case line(String), progress(SetupProgress) }
            let updates = AsyncStream<Update>.makeStream()
            let consumer = Task { @MainActor in
                for await update in updates.stream {
                    switch update {
                    case .line(let line): appendLog(line + "\n")
                    case .progress(let p):
                        setupStep = "Step \(p.step) of \(p.totalSteps): \(p.text)…"
                        setupPercent = p.percent
                    }
                }
            }
            do {
                let versions = try await setup.run(
                    runner: commands,
                    log: { updates.continuation.yield(.line($0)) },
                    progress: { updates.continuation.yield(.progress($0)) })
                updates.continuation.finish()
                await consumer.value
                let ffmpeg = versions.ffmpeg.components(separatedBy: " Copyright").first ?? versions.ffmpeg
                info = "Ready. spotdl \(versions.spotdl), \(ffmpeg)."
                appendLog("== Set up finished ==\n")
                showLog = false   // back to the usual layout; on failure the log stays open to show why
            } catch {
                updates.continuation.finish()
                await consumer.value
                notice = error.localizedDescription
                appendLog("Setup stopped: \(error.localizedDescription)\n")
            }
            needsSetup = !setup.isReady
            isSettingUp = false
        }
    }

    private func appendLog(_ s: String) { log += s }
}
