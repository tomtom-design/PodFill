import Foundation

/// Layout of the app's private data dir (the Mac twin of the Windows app's AppPaths). Everything PodFill installs
/// or writes, other than the MP3s, lives here, so uninstalling is "delete the app and this folder":
///
///     ~/Library/Application Support/PodFill/
///       uv/uv                    pinned uv release (verified download)
///       tools/spotdl/            the spotdl tool environment (UV_TOOL_DIR)
///       bin/spotdl               its launcher (UV_TOOL_BIN_DIR)
///       python/                  uv-managed Python (UV_PYTHON_INSTALL_DIR)
///       cache/                   uv cache (UV_CACHE_DIR)
///       home/.spotdl/            spotdl's own folder: config.json, ffmpeg, deno, temp, errors
///       deno-cache/              DENO_DIR
///
/// spotdl always uses "~/.spotdl" (Path.home() / ".spotdl"). Child processes get HOME pointed at home/, so that
/// folder lands inside the data dir and a real ~/.spotdl (another spotdl install) is never touched.
public struct AppPaths: Equatable, Sendable {
    /// Overrides the data dir. Tests and the CI smoke test set it so they never touch real locations.
    public static let dataDirVariable = "PODFILL_DATA_DIR"

    public let dataDir: String

    public init(dataDir: String) {
        self.dataDir = dataDir
    }

    /// The override if set, else ~/Library/Application Support/PodFill.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
        if let custom = environment[dataDirVariable]?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            return AppPaths(dataDir: URL(fileURLWithPath: custom).standardizedFileURL.path)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return AppPaths(dataDir: support.appendingPathComponent("PodFill").path)
    }

    private func path(_ parts: String...) -> String {
        ([dataDir.hasSuffix("/") && dataDir.count > 1 ? String(dataDir.dropLast()) : dataDir] + parts).joined(separator: "/")
    }

    public var uvDir: String { path("uv") }
    public var uv: String { path("uv", "uv") }
    public var toolDir: String { path("tools") }
    public var binDir: String { path("bin") }
    public var spotdl: String { path("bin", "spotdl") }
    public var pythonDir: String { path("python") }
    public var pythonBinDir: String { path("python-bin") }
    public var cacheDir: String { path("cache") }
    public var homeDir: String { path("home") }
    public var spotdlHome: String { path("home", ".spotdl") }
    /// Where `spotdl --download-ffmpeg` puts ffmpeg (spotdl.utils.ffmpeg.download_ffmpeg); passed back via --ffmpeg.
    public var ffmpeg: String { path("home", ".spotdl", "ffmpeg") }
    /// Where `spotdl --download-deno` puts Deno; spotdl hands it to yt-dlp as its JavaScript runtime.
    public var deno: String { path("home", ".spotdl", "deno") }
    public var spotdlTemp: String { path("home", ".spotdl", "temp") }
    public var denoDir: String { path("deno-cache") }
    public var downloadsDir: String { path("downloads") }

    /// Inherited variables that would make the private Python/uv behave differently from what we tested.
    static let removedVariables: Set<String> = [
        "VIRTUAL_ENV", "CONDA_PREFIX", "CONDA_DEFAULT_ENV", "PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP",
        "PYTHONUSERBASE", "PYTHONSAFEPATH", "FORCE_COLOR", "CLICOLOR_FORCE", "TERM",
    ]

    /// The environment for every child process (uv, spotdl and what they spawn). Same isolation as on Windows.
    /// PATH is the system one (what an app launched from Finder gets), so a Homebrew Python, ffmpeg or uv in the
    /// user's shell PATH can never be picked up instead of the private copies.
    public func childEnvironment(inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = inherited.filter { key, _ in !key.hasPrefix("UV_") && !Self.removedVariables.contains(key) }
        env["HOME"] = homeDir
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        // Python output: UTF-8 (song names are Unicode), unbuffered, no colors, no line wrapping.
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONUTF8"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["COLUMNS"] = "1000"
        env["NO_COLOR"] = "1"
        // uv: keep tools, Python, cache and shims inside the data dir; only uv-managed Python; ignore user config.
        env["UV_TOOL_DIR"] = toolDir
        env["UV_TOOL_BIN_DIR"] = binDir
        env["UV_PYTHON_INSTALL_DIR"] = pythonDir
        env["UV_PYTHON_BIN_DIR"] = pythonBinDir
        env["UV_PYTHON_INSTALL_BIN"] = "0"
        env["UV_PYTHON_INSTALL_REGISTRY"] = "0"
        env["UV_CACHE_DIR"] = cacheDir
        env["UV_MANAGED_PYTHON"] = "1"
        env["UV_NO_CONFIG"] = "1"
        env["UV_NO_PROGRESS"] = "1"
        // Deno (yt-dlp's JavaScript runtime): its cache in the data dir, no update checks.
        env["DENO_DIR"] = denoDir
        env["DENO_NO_UPDATE_CHECK"] = "1"
        return env
    }
}

/// One command line. `standardInput` is written to the child's stdin, which is then closed.
public struct ToolCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let standardInput: String?

    public init(_ executable: String, _ arguments: [String], standardInput: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.standardInput = standardInput
    }

    /// For the log: the command with arguments quoted where needed.
    public var display: String {
        ([executable] + arguments).map { a in
            a.isEmpty || a.contains(where: { $0.isWhitespace || "\"'{".contains($0) }) ? "\"\(a)\"" : a
        }.joined(separator: " ")
    }
}

/// The exact command lines PodFill runs. Must match the Windows app (the self-check compares the pins).
public enum Commands {
    /// spotdl 4.6 needs Python >=3.11,<3.16; 3.13 has prebuilt wheels for every dependency.
    public static let pythonVersion = "3.13"
    /// The output parser was verified against spotdl 4.6.0; stay on 4.x so an upgrade can't change the format under it.
    public static let spotdlRequirement = "spotdl>=4.6,<5"

    public static func installSpotdl(_ p: AppPaths) -> ToolCommand {
        ToolCommand(p.uv, ["tool", "install", spotdlRequirement, "--python", pythonVersion])
    }
    /// Re-resolves the whole tool environment, so yt-dlp (and yt-dlp-ejs) move to their latest release too.
    public static func upgradeSpotdl(_ p: AppPaths) -> ToolCommand { ToolCommand(p.uv, ["tool", "upgrade", "spotdl"]) }
    // Both prompt "already installed, overwrite? (y/N)" when an ffmpeg/deno is on PATH; answer yes so the private
    // copy is always written (stdin is otherwise closed, which would crash input()).
    public static func downloadFfmpeg(_ p: AppPaths) -> ToolCommand { ToolCommand(p.spotdl, ["--download-ffmpeg"], standardInput: "y\n") }
    public static func downloadDeno(_ p: AppPaths) -> ToolCommand { ToolCommand(p.spotdl, ["--download-deno"], standardInput: "y\n") }
    public static func uvVersion(_ p: AppPaths) -> ToolCommand { ToolCommand(p.uv, ["--version"]) }
    public static func spotdlVersion(_ p: AppPaths) -> ToolCommand { ToolCommand(p.spotdl, ["--version"]) }
    public static func ffmpegVersion(_ p: AppPaths) -> ToolCommand { ToolCommand(p.ffmpeg, ["-version"]) }
    public static func denoVersion(_ p: AppPaths) -> ToolCommand { ToolCommand(p.deno, ["--version"]) }

    public static func download(_ p: AppPaths, job: Job, destination: String) -> ToolCommand {
        ToolCommand(p.spotdl, job.arguments(ffmpeg: p.ffmpeg, destination: destination))
    }
}
