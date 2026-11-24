import Foundation

/// Finds the external tools. GUI apps launched from Finder don't inherit the shell PATH,
/// so every location is checked explicitly.
public struct Tools: Sendable {
    public var spotdl: String?
    public var ffmpeg: String?
    public var pipx: String?

    public static let home = NSHomeDirectory()

    public static var spotdlCandidates: [String] {
        ["\(home)/.local/bin/spotdl", "/opt/homebrew/bin/spotdl", "/usr/local/bin/spotdl"]
    }
    public static let ffmpegCandidates = [
        "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg",   // keg-only ffmpeg-full
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/opt/ffmpeg-full/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
    ]
    public static let pipxCandidates = ["/opt/homebrew/bin/pipx", "/usr/local/bin/pipx", "\(home)/.local/bin/pipx"]

    public static func locate() -> Tools {
        Tools(spotdl: firstExecutable(spotdlCandidates),
              ffmpeg: firstExecutable(ffmpegCandidates),
              pipx: firstExecutable(pipxCandidates))
    }

    static func firstExecutable(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Human-readable problems with the exact command that fixes each one.
    public var problems: [(message: String, fix: String)] {
        var out: [(String, String)] = []
        if spotdl == nil {
            out.append(("spotdl was not found.", "pipx install spotdl && pipx runpip spotdl install -U yt-dlp"))
        }
        if ffmpeg == nil {
            out.append(("ffmpeg was not found.", "brew install ffmpeg"))
        }
        return out
    }

    /// Minimal environment for child processes: a PATH that contains Homebrew and pipx
    /// (so yt-dlp can find deno), and a wide terminal so spotdl's output lines don't wrap.
    public static func childEnvironment() -> [String: String] {
        [
            "HOME": home,
            "USER": NSUserName(),
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "PYTHONIOENCODING": "utf-8",
            "PYTHONUNBUFFERED": "1",
            "COLUMNS": "1000",
            "NO_COLOR": "1",
        ]
    }
}
