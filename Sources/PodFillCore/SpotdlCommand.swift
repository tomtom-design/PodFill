import Foundation

/// Builds the spotdl command line. One `Job` is one spotdl invocation.
public struct Job: Equatable, Sendable {
    public let links: [SpotifyLink]
    public var title: String {
        links.count == 1 ? links[0].url : "\(links.count) tracks"
    }

    /// Albums and playlists run one job each (each gets its own folder); all single tracks share one job.
    public static func plan(for links: [SpotifyLink]) -> [Job] {
        var jobs = links.filter(\.isList).map { Job(links: [$0]) }
        let tracks = links.filter { !$0.isList }
        if !tracks.isEmpty { jobs.append(Job(links: tracks)) }
        return jobs
    }

    public func arguments(ffmpeg: String, destination: String) -> [String] {
        // Lists: <dest>/<Playlist or Album name>/Artist - Title.mp3
        // Tracks: <dest>/Singles/Artist - Title.mp3. With a track URL {list-name} is empty, which turns
        // the template into "/Artist - Title.mp3" (the filesystem root), so tracks must use their own template.
        let folder = links[0].isList ? "{list-name}" : "Singles"
        let template = "\(destination)/\(folder)/{artist} - {title}.{output-ext}"
        return ["download"] + links.map(\.url) + [
            "--ffmpeg", ffmpeg,
            "--format", "mp3",
            "--bitrate", "auto",      // keep the source bitrate; YouTube audio is ~128-160 kbps, re-encoding higher only bloats files
            "--threads", "4",
            "--overwrite", "skip",    // re-running a playlist only fetches new songs
            "--lyrics",               // no lyrics providers: they are slow, rate-limited, and the iPod doesn't need them
            "--simple-tui",           // plain line-based progress, parseable
            "--log-level", "INFO",
            "--output", template,
        ]
    }
}
