using System.Text.RegularExpressions;

namespace PodFill.Core;

public enum SongState { Searching, Downloading, Tagging, Done, AlreadyHad, Failed }

public readonly record struct SongStatus(SongState State, string? Reason = null)
{
    public static SongStatus Searching => new(SongState.Searching);
    public static SongStatus Downloading => new(SongState.Downloading);
    public static SongStatus Tagging => new(SongState.Tagging);
    public static SongStatus Done => new(SongState.Done);
    public static SongStatus AlreadyHad => new(SongState.AlreadyHad);
    public static SongStatus Failed(string reason) => new(SongState.Failed, reason);

    public bool IsFinished => State is SongState.Done or SongState.AlreadyHad or SongState.Failed;

    public string Label => State switch
    {
        SongState.Searching => "Searching",
        SongState.Downloading => "Downloading",
        SongState.Tagging => "Tagging",
        SongState.Done => "Done",
        SongState.AlreadyHad => "Already had it",
        _ => $"Failed: {Reason}",
    };
}

public abstract record OutputEvent
{
    public sealed record Found(int Count, string ListName) : OutputEvent;
    public sealed record Song(string Name, SongStatus Status) : OutputEvent;
    public sealed record Progress(int Done, int Total) : OutputEvent;
    /// <summary>"FFmpegError", "Failed to convert ...".</summary>
    public sealed record Error(string Kind, string Message) : OutputEvent;
    public sealed record Ignored : OutputEvent
    {
        public static readonly Ignored Instance = new();
    }
}

/// <summary>
/// What spotdl's <c>--simple-tui --log-level INFO</c> output tells us. Formats were captured from spotdl 4.6.0
/// (see ../fixtures and the tests), identical to the Mac app's OutputParser.swift:
/// <code>
/// Processing query: https://open.spotify.com/album/...
/// Found 12 songs in OK Computer (Album)          &lt;- only for albums/playlists
/// Radiohead - Airbag: Searching for song
/// Radiohead - Airbag: Getting audio meta
/// Radiohead - Airbag: Downloading
/// Radiohead - Airbag: Embedding metadata
/// Radiohead - Airbag: Done
/// 1/12 complete
/// Downloaded "Radiohead - Airbag": https://music.youtube.com/watch?v=...
/// Skipping Radiohead - Fitter Happier (file already exists) (duplicate)
/// Radiohead - Fitter Happier: Skipped
/// FFmpegError: Failed to convert Rick Astley - Never Gonna Give You Up, you can find error here:
/// </code>
/// </summary>
public static partial class OutputParser
{
    private static readonly (string Suffix, SongStatus Status)[] StatusSuffixes =
    [
        ("Searching for song", SongStatus.Searching),
        ("Getting audio meta", SongStatus.Searching),
        ("Downloading", SongStatus.Downloading),
        ("Embedding metadata", SongStatus.Tagging),
        ("Done", SongStatus.Done),
        ("Skipped", SongStatus.AlreadyHad),
    ];

    [GeneratedRegex(@"^Found (\d+) songs? in (.+) \((?:Album|Playlist|Artist|Saved|.+)\)$")]
    private static partial Regex FoundRegex();

    [GeneratedRegex(@"^(\d+)/(\d+) complete$")]
    private static partial Regex ProgressRegex();

    // Logged by spotdl as "<ExceptionClass>: <message>", e.g. "LookupError: No results found for song: X".
    [GeneratedRegex(@"^([A-Za-z]+(?:Error|Exception)): (.+)$")]
    private static partial Regex ErrorRegex();

    public static OutputEvent Parse(string rawLine)
    {
        var line = rawLine.Trim();
        if (line.Length == 0) return OutputEvent.Ignored.Instance;

        if (FoundRegex().Match(line) is { Success: true } f)
            return new OutputEvent.Found(int.Parse(f.Groups[1].Value), f.Groups[2].Value);
        if (ProgressRegex().Match(line) is { Success: true } p)
            return new OutputEvent.Progress(int.Parse(p.Groups[1].Value), int.Parse(p.Groups[2].Value));
        if (line == "Error") return OutputEvent.Ignored.Instance;

        foreach (var (suffix, status) in StatusSuffixes)
        {
            if (line.EndsWith(": " + suffix, StringComparison.Ordinal))
            {
                var name = line[..^(suffix.Length + 2)];
                if (name.Length > 0) return new OutputEvent.Song(name, status);
            }
        }
        if (line.EndsWith(": Error", StringComparison.Ordinal))
            return new OutputEvent.Song(line[..^7], SongStatus.Failed("Error"));

        if (ErrorRegex().Match(line) is { Success: true } e)
            return new OutputEvent.Error(e.Groups[1].Value, e.Groups[2].Value);

        return OutputEvent.Ignored.Instance;
    }

    /// <summary>Which of the known song names does an error message talk about? Longest name wins.</summary>
    public static string? SongMentionedIn(string message, IEnumerable<string> names) =>
        names.Where(n => message.Contains(n, StringComparison.Ordinal))
             .OrderByDescending(n => n.Length)
             .FirstOrDefault();

    /// <summary>Plain-language reason for a spotdl error.</summary>
    public static string Reason(string kind, string message) => kind switch
    {
        "LookupError" => "No matching audio found on YouTube Music",
        "FFmpegError" => "ffmpeg could not convert the audio",
        "AudioProviderError" => "YouTube download failed. Try Update downloader",
        _ => $"{kind}: {message}",
    };
}
