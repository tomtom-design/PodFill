import Foundation

/// What spotdl's `--simple-tui --log-level INFO` output tells us. Formats were captured from spotdl 4.6.0
/// (see fixtures/ and the tests):
///
///     Processing query: https://open.spotify.com/album/...
///     Found 12 songs in OK Computer (Album)          <- only for albums/playlists
///     Radiohead - Airbag: Searching for song
///     Radiohead - Airbag: Getting audio meta
///     Radiohead - Airbag: Downloading
///     Radiohead - Airbag: Embedding metadata
///     Radiohead - Airbag: Done
///     1/12 complete
///     Downloaded "Radiohead - Airbag": https://music.youtube.com/watch?v=...
///     Skipping Radiohead - Fitter Happier (file already exists) (duplicate)
///     Radiohead - Fitter Happier: Skipped
///     FFmpegError: Failed to convert Rick Astley - Never Gonna Give You Up, you can find error here:
public enum SongStatus: Equatable, Sendable {
    case searching, downloading, tagging, done, alreadyHad
    case failed(String)

    public var isFinished: Bool {
        switch self {
        case .done, .alreadyHad, .failed: return true
        default: return false
        }
    }
}

public enum OutputEvent: Equatable, Sendable {
    case found(count: Int, listName: String)
    case song(name: String, status: SongStatus)
    case progress(done: Int, total: Int)
    case error(kind: String, message: String)   // "FFmpegError", "Failed to convert ..."
    case ignored
}

public enum OutputParser {
    private static let statusSuffixes: [(String, SongStatus)] = [
        ("Searching for song", .searching),
        ("Getting audio meta", .searching),
        ("Downloading", .downloading),
        ("Embedding metadata", .tagging),
        ("Done", .done),
        ("Skipped", .alreadyHad),
    ]

    private static let found = try! NSRegularExpression(pattern: #"^Found (\d+) songs? in (.+) \((?:Album|Playlist|Artist|Saved|.+)\)$"#)
    private static let progress = try! NSRegularExpression(pattern: #"^(\d+)/(\d+) complete$"#)
    // Logged by spotdl as "<ExceptionClass>: <message>", e.g. "LookupError: No results found for song: X".
    private static let error = try! NSRegularExpression(pattern: #"^([A-Za-z]+(?:Error|Exception)): (.+)$"#)

    public static func parse(_ rawLine: String) -> OutputEvent {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return .ignored }

        if let m = match(found, line) {
            return .found(count: Int(m[1])!, listName: m[2])
        }
        if let m = match(progress, line) {
            return .progress(done: Int(m[1])!, total: Int(m[2])!)
        }
        if line == "Error" { return .ignored }
        for (suffix, status) in statusSuffixes where line.hasSuffix(": \(suffix)") {
            let name = String(line.dropLast(suffix.count + 2))
            if !name.isEmpty { return .song(name: name, status: status) }
        }
        if line.hasSuffix(": Error") {
            return .song(name: String(line.dropLast(7)), status: .failed("Error"))
        }
        if let m = match(error, line) {
            return .error(kind: m[1], message: m[2])
        }
        return .ignored
    }

    /// Which of the known song names does an error message talk about? Longest name wins.
    public static func song(mentionedIn message: String, among names: [String]) -> String? {
        names.filter { message.contains($0) }.max { $0.count < $1.count }
    }

    /// Plain-language reason for a spotdl error.
    public static func reason(kind: String, message: String) -> String {
        switch kind {
        case "LookupError": return "No matching audio found on YouTube Music"
        case "FFmpegError": return "ffmpeg could not convert the audio"
        case "AudioProviderError": return "YouTube download failed. Try Update downloader"
        default: return "\(kind): \(message)"
        }
    }

    private static func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range) else { return nil }
        return (0..<m.numberOfRanges).map { String(s[Range(m.range(at: $0), in: s)!]) }
    }
}
