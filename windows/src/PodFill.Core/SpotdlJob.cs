namespace PodFill.Core;

/// <summary>One spotdl invocation. Same plan and arguments as the Mac app's SpotdlCommand.swift.</summary>
public sealed record SpotdlJob(IReadOnlyList<SpotifyLink> Links)
{
    public string Title => Links.Count == 1 ? Links[0].Url : $"{Links.Count} tracks";

    /// <summary>Albums and playlists run one job each (each gets its own folder); all single tracks share one job.</summary>
    public static IReadOnlyList<SpotdlJob> Plan(IReadOnlyList<SpotifyLink> links)
    {
        var jobs = links.Where(l => l.IsList).Select(l => new SpotdlJob([l])).ToList();
        var tracks = links.Where(l => !l.IsList).ToList();
        if (tracks.Count > 0) jobs.Add(new SpotdlJob(tracks));
        return jobs;
    }

    /// <summary>
    /// Lists: &lt;dest&gt;\&lt;Playlist or Album name&gt;\Artist - Title.mp3. Tracks: &lt;dest&gt;\Singles\Artist - Title.mp3.
    /// With a track URL spotdl's {list-name} is empty, which turns the template into "\Artist - Title.mp3"
    /// (the drive root), so tracks get their own folder name instead.
    /// spotdl only sanitizes the substituted values, never the literal part of the template, so a drive letter
    /// (C:), a UNC prefix or spaces in the destination survive as they are (checked against spotdl 4.6.0's
    /// formatter.create_file_name with PureWindowsPath).
    /// </summary>
    public string OutputTemplate(string destination, char separator)
    {
        var folder = Links[0].IsList ? "{list-name}" : "Singles";
        var root = destination.TrimEnd('/', '\\');
        return $"{root}{separator}{folder}{separator}{{artist}} - {{title}}.{{output-ext}}";
    }

    public IReadOnlyList<string> Arguments(string ffmpeg, string destination, char separator)
    {
        var args = new List<string> { "download" };
        args.AddRange(Links.Select(l => l.Url));
        args.AddRange([
            "--ffmpeg", ffmpeg,
            "--format", "mp3",
            "--bitrate", "auto",     // keep the source bitrate; YouTube audio is ~128-160 kbps, re-encoding higher only bloats files
            "--threads", "4",
            "--overwrite", "skip",   // re-running a playlist only fetches new songs
            "--lyrics",              // no lyrics providers: they are slow, rate-limited, and the iPod doesn't need them
            "--simple-tui",          // plain line-based progress, parseable
            "--log-level", "INFO",
            "--output", OutputTemplate(destination, separator),
        ]);
        return args;
    }
}
