import CryptoKit
import Foundation

/// A setup failure with a plain-language message for the user.
public struct SetupError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct SetupProgress: Equatable, Sendable {
    public let step: Int
    public let totalSteps: Int
    public let text: String
    public let percent: Double?
}

public struct EngineVersions: Equatable, Sendable {
    public let uv, spotdl, ffmpeg, deno: String
}

/// Runs commands with the data-dir environment and remembers the one in flight, so Cancel can kill it.
public final class CommandRunner: @unchecked Sendable {
    public let paths: AppPaths
    public let environment: [String: String]
    private let lock = NSLock()
    private var current: ProcessRunner?

    public init(paths: AppPaths, inherited: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.environment = paths.childEnvironment(inherited: inherited)
    }

    public func run(_ command: ToolCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let runner = ProcessRunner()
        lock.withLock { current = runner }
        defer { lock.withLock { if current === runner { current = nil } } }
        try FileManager.default.createDirectory(atPath: paths.homeDir, withIntermediateDirectories: true)
        return try await runner.run(executable: command.executable, arguments: command.arguments, environment: environment,
                                    input: command.standardInput, currentDirectory: paths.homeDir, onLine: onLine)
    }

    /// Runs a command and returns its exit status and its whole output (for version checks).
    public func capture(_ command: ToolCommand) async throws -> (status: Int32, output: String) {
        let box = LineBox()
        let status = try await run(command) { box.append($0) }
        return (status, box.text)
    }

    /// Kills the running command and all its descendants (spotdl -> python -> ffmpeg).
    public func killCurrent() {
        lock.withLock { current }?.terminateTree()
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var text: String { lock.withLock { lines.joined(separator: "\n") } }
}

/// The one-time "Set up" (and repair): uv, spotdl + Python, ffmpeg, Deno, then a version check.
/// A port of the Windows app's SetupService; the app's Set up button and the CI smoke test both run it.
/// Every step is skipped when its result is already in place, so running it again is a cheap repair.
public final class SetupService: Sendable {
    public static let totalSteps = 5
    /// Ephemeral: no URL cache or cookies written to ~/Library (nothing outside the data dir).
    private static let session = URLSession(configuration: .ephemeral)
    public let paths: AppPaths
    public let arch: UvRelease.Arch

    public init(paths: AppPaths, arch: UvRelease.Arch = UvRelease.machineArch()) {
        self.paths = paths
        self.arch = arch
    }

    /// Everything a download needs is installed.
    public var isReady: Bool {
        let fm = FileManager.default
        return [paths.uv, paths.spotdl, paths.ffmpeg, paths.deno].allSatisfy { fm.isExecutableFile(atPath: $0) }
    }

    public func run(runner: CommandRunner, log: @escaping @Sendable (String) -> Void,
                    progress: @escaping @Sendable (SetupProgress) -> Void) async throws -> EngineVersions {
        let fm = FileManager.default
        try fm.createDirectory(atPath: paths.homeDir, withIntermediateDirectories: true)
        @Sendable func step(_ n: Int, _ text: String, _ percent: Double? = nil) {
            progress(SetupProgress(step: n, totalSteps: Self.totalSteps, text: text, percent: percent))
        }

        // 1. uv
        step(1, "Downloading uv \(UvRelease.version)", 0)
        if await uvIsCurrent(runner) {
            log("uv \(UvRelease.version) is already installed.")
        } else {
            try await installUv(log: log) { step(1, "Downloading uv \(UvRelease.version)", $0) }
        }

        // 2. spotdl (uv also downloads its private Python). A no-op when it is already installed.
        step(2, "Installing spotdl and Python \(Commands.pythonVersion)")
        try await runStep(runner, Commands.installSpotdl(paths), log, failure: "Installing spotdl failed")
        guard fm.isExecutableFile(atPath: paths.spotdl) else { throw SetupError("uv finished but spotdl is missing. See the log.") }

        // 3. ffmpeg, through spotdl's own downloader (a native arm64 or x86_64 build, written to home/.spotdl/ffmpeg).
        step(3, "Downloading ffmpeg")
        if fm.isExecutableFile(atPath: paths.ffmpeg), (try? await runner.capture(Commands.ffmpegVersion(paths)))?.status == 0 {
            log("ffmpeg is already installed.")
        } else {
            try await runStep(runner, Commands.downloadFfmpeg(paths), log, failure: "Downloading ffmpeg failed")
            guard fm.isExecutableFile(atPath: paths.ffmpeg) else { throw SetupError("spotdl could not download ffmpeg for this Mac. See the log.") }
        }

        // 4. Deno: yt-dlp needs a JavaScript runtime for YouTube; spotdl passes its local copy to yt-dlp.
        step(4, "Downloading Deno (needed by the YouTube downloader)")
        if fm.isExecutableFile(atPath: paths.deno) {
            log("Deno is already installed.")
        } else {
            try await runStep(runner, Commands.downloadDeno(paths), log, failure: "Downloading Deno failed")
            guard fm.isExecutableFile(atPath: paths.deno) else { throw SetupError("spotdl could not download Deno for this Mac. See the log.") }
        }

        // 5. Does everything run?
        step(5, "Checking")
        let versions = try await verify(runner: runner, log: log)
        try? fm.removeItem(atPath: paths.downloadsDir)
        return versions
    }

    /// Runs uv, spotdl, ffmpeg and Deno once and returns their versions.
    public func verify(runner: CommandRunner, log: @escaping @Sendable (String) -> Void) async throws -> EngineVersions {
        func version(_ command: ToolCommand, _ what: String) async throws -> String {
            log("$ \(command.display)")
            let (status, output) = try await runner.capture(command)
            let first = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            log(first)
            guard status == 0, !first.isEmpty else { throw SetupError("\(what) does not run (exit code \(status)). Click Set up again.") }
            return first
        }
        return EngineVersions(uv: try await version(Commands.uvVersion(paths), "uv"),
                              spotdl: try await version(Commands.spotdlVersion(paths), "spotdl"),
                              ffmpeg: try await version(Commands.ffmpegVersion(paths), "ffmpeg"),
                              deno: try await version(Commands.denoVersion(paths), "Deno"))
    }

    private func uvIsCurrent(_ runner: CommandRunner) async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: paths.uv),
              let (status, output) = try? await runner.capture(Commands.uvVersion(paths)) else { return false }
        return status == 0 && output.hasPrefix("uv \(UvRelease.version) ")
    }

    private func runStep(_ runner: CommandRunner, _ command: ToolCommand, _ log: @escaping @Sendable (String) -> Void,
                         failure: String) async throws {
        log("$ \(command.display)")
        let status: Int32
        do { status = try await runner.run(command, onLine: log) } catch {
            throw SetupError("\(failure): could not start \((command.executable as NSString).lastPathComponent) (\(error.localizedDescription)).")
        }
        guard status == 0 else { throw SetupError("\(failure) (exit code \(status)). See the log.") }
    }

    /// Downloads the pinned uv archive, checks it against the published .sha256 and the built-in pin, unpacks uv.
    func installUv(log: @escaping @Sendable (String) -> Void, percent: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let asset = UvRelease.asset(for: arch)
        try fm.createDirectory(atPath: paths.downloadsDir, withIntermediateDirectories: true)
        let archive = paths.downloadsDir + "/" + asset.name
        do {
            log("Downloading \(asset.checksumURL.absoluteString)")
            let (data, response) = try await Self.session.data(from: asset.checksumURL)
            try Self.checkOK(response)
            let published = try UvRelease.parseChecksumFile(String(decoding: data, as: UTF8.self))
            guard published == asset.sha256 else {
                throw SetupError("The published uv checksum does not match the one built into PodFill. Setup stopped for safety.")
            }
            log("Downloading \(asset.url.absoluteString)")
            try await Self.download(asset.url, to: archive, percent: percent)
        } catch let error as SetupError {
            throw error
        } catch {
            throw SetupError("Could not download uv. Check the internet connection and try again. (\(error.localizedDescription))")
        }

        let actual = try Self.sha256(ofFile: archive)
        log("sha256 \(actual) (published and pinned: \(asset.sha256))")
        guard actual == asset.sha256 else {
            try? fm.removeItem(atPath: archive)
            throw SetupError("The uv download is damaged (checksum mismatch). Click Set up to try again.")
        }

        let staging = paths.downloadsDir + "/uv-extract"
        try? fm.removeItem(atPath: staging)
        try Self.extract(archive: archive, to: staging)
        // The macOS tarballs hold uv-<target>/uv and uvx.
        guard let found = fm.enumerator(atPath: staging)?.compactMap({ $0 as? String }).first(where: { ($0 as NSString).lastPathComponent == "uv" })
        else { throw SetupError("The uv download did not contain uv.") }
        let sourceDir = (staging + "/" + found as NSString).deletingLastPathComponent
        try? fm.removeItem(atPath: paths.uvDir)
        try fm.createDirectory(atPath: paths.uvDir, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: sourceDir) {
            let target = paths.uvDir + "/" + name
            try fm.moveItem(atPath: sourceDir + "/" + name, toPath: target)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
        }
        try? fm.removeItem(atPath: staging)
        try? fm.removeItem(atPath: archive)
        log("uv \(UvRelease.version) installed in \(paths.uvDir)")
    }

    /// Unpacks a .tar.gz with the system tar (which refuses absolute paths and "..").
    public static func extract(archive: String, to destination: String) throws {
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive, "-C", destination]
        tar.standardInput = FileHandle.nullDevice
        let errors = Pipe()
        tar.standardError = errors
        try tar.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw SetupError("Could not unpack \((archive as NSString).lastPathComponent): \(message)") }
    }

    public static func sha256(ofFile path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func checkOK(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SetupError("Download failed (HTTP \(http.statusCode)).")
        }
    }

    private static func download(_ url: URL, to path: String, percent: @escaping @Sendable (Double) -> Void) async throws {
        let (bytes, response) = try await session.bytes(from: url)
        try checkOK(response)
        let total = response.expectedContentLength
        FileManager.default.createFile(atPath: path, contents: nil)
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? file.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var written: Int64 = 0
        var lastReported = -1
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == 1 << 16 {
                try file.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0, Int(written * 100 / total) != lastReported {
                    lastReported = Int(written * 100 / total)
                    percent(Double(lastReported))
                }
            }
        }
        try file.write(contentsOf: buffer)
        percent(100)
    }
}
