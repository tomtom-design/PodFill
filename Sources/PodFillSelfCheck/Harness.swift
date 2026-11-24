import Foundation
import PodFillCore

/// Drives the app's DownloadModel headless, on the main actor like the window does:
///
///     PODFILL_DATA_DIR=<dir> PodFillSelfCheck --download --dest <folder> <spotify-url>...
///     PODFILL_DATA_DIR=<dir> PodFillSelfCheck --cancel [--after S] --dest <folder> <album-url>
///     PODFILL_DATA_DIR=<dir> PodFillSelfCheck --update
///
/// --cancel presses Cancel S seconds (default 4) after the first song starts downloading, then checks that no
/// process started from the data dir survived and lists what is left in the destination.
@MainActor
enum Harness {
    static func main(_ args: [String]) async -> Int32 {
        var dest: String?
        var after = 4.0
        var urls: [String] = []
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--dest" where i + 1 < args.count: dest = args[i + 1]; i += 1
            case "--after" where i + 1 < args.count: after = Double(args[i + 1]) ?? after; i += 1
            default: urls.append(args[i])
            }
            i += 1
        }
        if args[0] == "--update" {
            guard ProcessInfo.processInfo.environment[AppPaths.dataDirVariable] != nil else { print("Set PODFILL_DATA_DIR."); return 2 }
            let model = DownloadModel()
            guard !model.needsSetup else { print("Not set up."); return 1 }
            model.updateDownloader()
            await model.currentWork?.value
            report(model)
            return model.notice == nil ? 0 : 1
        }
        guard let dest, !urls.isEmpty, ProcessInfo.processInfo.environment[AppPaths.dataDirVariable] != nil else {
            print("usage: PODFILL_DATA_DIR=<dir> PodFillSelfCheck --download|--cancel [--after S] --dest <folder> <url>...")
            return 2
        }
        // The model reads its destination from UserDefaults; a volatile argument domain sets it without writing prefs.
        let folder = URL(fileURLWithPath: dest).standardizedFileURL.path
        UserDefaults.standard.setVolatileDomain(["destinationPath": folder], forName: UserDefaults.argumentDomain)

        let model = DownloadModel()
        print("data dir: \(model.paths.dataDir)\ndestination: \(model.destination)")
        guard !model.needsSetup else { print("Not set up: run --setup-smoke with the same PODFILL_DATA_DIR first."); return 1 }
        model.urlText = urls.joined(separator: "\n")
        guard model.canDownload else { print("No valid Spotify link."); return 1 }
        model.start()

        if args[0] == "--cancel" {
            let started = Date()
            var firstDownload: Date?
            while model.isRunning {
                if firstDownload == nil, model.songs.contains(where: { $0.status == .downloading || $0.status == .tagging }) {
                    firstDownload = Date()
                }
                if let t = firstDownload, Date().timeIntervalSince(t) > after { break }
                if Date().timeIntervalSince(started) > 180 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let before = processes(under: model.paths.dataDir)
            print(String(format: ">>> CANCEL at %.1fs; processes running from the data dir:", Date().timeIntervalSince(started)))
            before.forEach { print("    \($0)") }
            let pressed = Date()
            model.cancel()
            await model.currentWork?.value
            print(String(format: ">>> run returned %.1fs after Cancel", Date().timeIntervalSince(pressed)))
            try? await Task.sleep(for: .seconds(1))
            let after = processes(under: model.paths.dataDir)
            report(model)
            print(">>> processes from the data dir 1 s after the run returned: \(after.count)")
            after.forEach { print("    \($0)") }
            return !before.isEmpty && after.isEmpty ? 0 : 1
        }

        await model.currentWork?.value
        report(model)
        return !model.songs.isEmpty && model.songs.allSatisfy({ $0.status == .done || $0.status == .alreadyHad }) ? 0 : 1
    }

    static func report(_ model: DownloadModel) {
        print(model.log)
        print("--- result ---")
        if let notice = model.notice { print("notice: \(notice)") }
        if let info = model.info { print("info: \(info)") }
        if model.overallTotal > 0 { print("progress: \(model.overallDone) of \(model.overallTotal)") }
        for song in model.songs { print("  [\(label(song.status))] \(song.name)") }
        print("\(model.newFiles.count) new file(s):")
        model.newFiles.forEach { print("  \($0.path)") }
    }

    static func label(_ s: SongStatus) -> String {
        switch s {
        case .searching: "Searching"
        case .downloading: "Downloading"
        case .tagging: "Tagging"
        case .done: "Done"
        case .alreadyHad: "Already had it"
        case .failed(let why): "Failed: \(why)"
        }
    }

    /// Processes whose command line mentions the data dir (uv, python/spotdl, ffmpeg, deno), except this one.
    static func processes(under dataDir: String) -> [String] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,ppid=,command="]
        let out = Pipe()
        ps.standardOutput = out
        guard (try? ps.run()) != nil else { return ["ps failed"] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        let me = String(ProcessInfo.processInfo.processIdentifier)
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains(dataDir) && !$0.hasPrefix(me + " ") }
            .map { $0.count > 180 ? String($0.prefix(180)) + "..." : $0 }
    }
}
