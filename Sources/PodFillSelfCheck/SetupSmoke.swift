import Foundation
import PodFillCore

/// `PODFILL_DATA_DIR=<dir> PodFillSelfCheck --setup-smoke`: the app's real first-launch setup (SetupService) in a
/// throwaway data dir: pinned uv download + sha256 check, `uv tool install spotdl`, ffmpeg, Deno, the version check,
/// then Update downloader (`uv tool upgrade spotdl`). No Spotify or YouTube queries.
/// Fails if anything lands outside the data dir.
enum SetupSmoke {
    nonisolated(unsafe) static var failed = false

    static func run() -> Int32 {
        guard let custom = ProcessInfo.processInfo.environment[AppPaths.dataDirVariable],
              !custom.trimmingCharacters(in: .whitespaces).isEmpty else {
            print("Set \(AppPaths.dataDirVariable) to a throwaway folder first.")
            return 2
        }
        let paths = AppPaths.current()
        print("data dir: \(paths.dataDir)")
        let outside = OutsideGuard(excluding: paths.dataDir)
        let runner = CommandRunner(paths: paths)
        let setup = SetupService(paths: paths)
        let done = DispatchSemaphore(value: 0)

        Task.detached {
            do {
                let v = try await setup.run(runner: runner, log: { print($0) }, progress: { p in
                    if p.percent == nil || p.percent == 0 { print(">> step \(p.step)/\(p.totalSteps): \(p.text)") }
                })
                print("\nuv:     \(v.uv)\nspotdl: \(v.spotdl)\nffmpeg: \(v.ffmpeg)\ndeno:   \(v.deno)")
                print("ffmpeg passed to spotdl --ffmpeg: \(paths.ffmpeg)")
                print(describe(paths.ffmpeg))

                let update = Commands.upgradeSpotdl(paths)
                print("\n$ \(update.display)")
                let status = try await runner.run(update) { print($0) }
                if status != 0 { print("Update downloader failed (exit \(status))"); failed = true }
            } catch {
                print("SETUP FAILED: \(error.localizedDescription)")
                failed = true
            }
            done.signal()
        }
        done.wait()

        let leaks = outside.changes()
        print("\nChecked outside the data dir: \(outside.paths.count) locations")
        for leak in leaks { print("WROTE OUTSIDE THE DATA DIR: \(leak)") }
        if leaks.isEmpty { print("nothing written outside the data dir") }
        let ok = !failed && leaks.isEmpty && setup.isReady
        print(ok ? "SETUP SMOKE TEST PASSED" : "SETUP SMOKE TEST FAILED")
        return ok ? 0 : 1
    }

    /// `file <binary>`: shows which architecture spotdl's ffmpeg download is.
    static func describe(_ binary: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/file")
        p.arguments = ["-b", binary]
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return "file: could not run" }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return "file ffmpeg: " + text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Snapshots the places uv, spotdl, yt-dlp, Deno and URLSession would write to if the isolation leaked, and reports
/// any that appeared or changed (the path itself or one of its direct children; symlinks are not followed).
struct OutsideGuard {
    struct Mark: Equatable {
        let exists: Bool
        let modified: Date?
        let children: [String: Date]
    }

    let paths: [String]
    private let before: [String: Mark]

    init(excluding dataDir: String) {
        let home = NSHomeDirectory()
        let paths = [
            ".spotdl", ".config/spotdl",                                    // spotdl's home folder
            ".local/bin", ".local/share/uv", ".cache/uv", ".config/uv",     // uv tools, Pythons, cache, config
            "Library/Caches/uv", "Library/Application Support/uv",
            ".cache/yt-dlp", ".deno", "Library/Caches/deno",                // yt-dlp cache, Deno cache
            "Library/Application Support/PodFill",                          // the real data dir
            "Library/Caches/PodFillSelfCheck", "Library/HTTPStorages/PodFillSelfCheck",   // URLSession storage
        ].map { home + "/" + $0 }.filter { !$0.hasPrefix(dataDir) && !dataDir.hasPrefix($0 + "/") }
        self.init(paths: paths)
    }

    init(paths: [String]) {
        self.paths = paths
        before = Dictionary(uniqueKeysWithValues: paths.map { ($0, Self.mark($0)) })
    }

    static func mark(_ path: String) -> Mark {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return Mark(exists: false, modified: nil, children: [:]) }
        var children: [String: Date] = [:]
        if attrs[.type] as? FileAttributeType == .typeDirectory {
            for name in (try? fm.contentsOfDirectory(atPath: path)) ?? [] {
                children[name] = (try? fm.attributesOfItem(atPath: path + "/" + name))?[.modificationDate] as? Date
            }
        }
        return Mark(exists: true, modified: attrs[.modificationDate] as? Date, children: children)
    }

    func changes() -> [String] { paths.filter { Self.mark($0) != before[$0] } }
}
