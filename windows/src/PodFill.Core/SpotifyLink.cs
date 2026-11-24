namespace PodFill.Core;

public enum LinkKind { Track, Album, Playlist }

/// <summary>A Spotify link the app knows how to hand to spotdl.</summary>
public sealed record SpotifyLink(LinkKind Kind, string Id)
{
    /// <summary>Canonical URL without tracking parameters (<c>?si=...</c>) or locale prefixes (<c>/intl-fr/</c>).</summary>
    public string Url => $"https://open.spotify.com/{KindName(Kind)}/{Id}";

    public bool IsList => Kind != LinkKind.Track;

    internal static string KindName(LinkKind kind) => kind switch
    {
        LinkKind.Track => "track",
        LinkKind.Album => "album",
        _ => "playlist",
    };

    internal static LinkKind? ParseKind(string s) => s switch
    {
        "track" => LinkKind.Track,
        "album" => LinkKind.Album,
        "playlist" => LinkKind.Playlist,
        _ => null,
    };
}

public static class SpotifyUrl
{
    private static readonly char[] Separators = [' ', '\t', '\n', '\r', '\f', '\v', ','];
    private static readonly string[] Hosts = ["open.spotify.com", "spotify.com", "play.spotify.com"];

    /// <summary>Splits pasted text into links. Returns the valid links (deduplicated, in order) and the tokens that were not understood.</summary>
    public static (IReadOnlyList<SpotifyLink> Links, IReadOnlyList<string> Rejected) Parse(string text)
    {
        var links = new List<SpotifyLink>();
        var rejected = new List<string>();
        foreach (var token in text.Split(Separators, StringSplitOptions.RemoveEmptyEntries))
        {
            if (LinkFrom(token) is { } link)
            {
                if (!links.Contains(link)) links.Add(link);
            }
            else
            {
                rejected.Add(token);
            }
        }
        return (links, rejected);
    }

    internal static SpotifyLink? LinkFrom(string token)
    {
        // Also accept spotify:track:ID URIs.
        if (token.StartsWith("spotify:", StringComparison.Ordinal))
        {
            var parts = token.Split(':');
            return parts.Length == 3 && SpotifyLink.ParseKind(parts[1]) is { } k && IsId(parts[2])
                ? new SpotifyLink(k, parts[2])
                : null;
        }

        if (!Uri.TryCreate(token, UriKind.Absolute, out var uri)
            || (uri.Scheme != Uri.UriSchemeHttps && uri.Scheme != Uri.UriSchemeHttp)
            || !Hosts.Contains(uri.Host, StringComparer.OrdinalIgnoreCase))
        {
            return null;
        }

        var path = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries).ToList();
        if (path.Count > 0 && path[0].StartsWith("intl-", StringComparison.Ordinal)) path.RemoveAt(0);
        return path.Count >= 2 && SpotifyLink.ParseKind(path[0]) is { } kind && IsId(path[1])
            ? new SpotifyLink(kind, path[1])
            : null;
    }

    private static bool IsId(string s) => s.Length > 0 && s.All(char.IsAsciiLetterOrDigit);
}
