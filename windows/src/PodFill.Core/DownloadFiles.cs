using System.Text.Json;
using System.Text.Json.Nodes;

namespace PodFill.Core;

/// <summary>Finding the MP3s a run wrote, and cleaning up after a cancel. Same rules as the Mac app.</summary>
public static class DownloadFiles
{
    /// <summary>MP3s written since <paramref name="startedUtc"/> (older, skipped files keep their old modification time).</summary>
    public static IReadOnlyList<string> CollectNew(string destination, DateTime startedUtc)
    {
        if (!Directory.Exists(destination)) return [];
        var cutoff = startedUtc.AddSeconds(-1);
        try
        {
            var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, MatchCasing = MatchCasing.CaseInsensitive };
            return Directory.EnumerateFiles(destination, "*.mp3", options)
                            .Where(f => File.GetLastWriteTimeUtc(f) >= cutoff)
                            .Order(StringComparer.Ordinal)
                            .ToList();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return []; }
    }

    /// <summary>Lowercased letters and digits only, so "Artist - Title" matches "Artist - Title.mp3" whatever spotdl sanitized.</summary>
    public static string Normalize(string s) =>
        new(s.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());

    /// <summary>
    /// Killing ffmpeg mid-write leaves a truncated MP3 that spotdl would later skip as "already exists".
    /// Picks the new files whose name matches a song that was still in progress when the run was cancelled.
    /// spotdl's display name ("Artist - Title") and the "{artist} - {title}" file name both use the primary artist only.
    /// </summary>
    public static IReadOnlyList<string> PartialFiles(IEnumerable<string> newFiles, IEnumerable<string> unfinishedSongNames)
    {
        var unfinished = unfinishedSongNames.Select(Normalize).ToHashSet();
        return newFiles.Where(f => unfinished.Contains(Normalize(Path.GetFileNameWithoutExtension(f)))).ToList();
    }

    /// <summary>Deletes a file, retrying briefly: on Windows a just-killed ffmpeg can hold it for a moment.</summary>
    public static bool DeleteWithRetry(string path)
    {
        for (var attempt = 0; attempt < 10; attempt++)
        {
            try
            {
                if (File.Exists(path)) File.Delete(path);
                return true;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Thread.Sleep(200);
            }
        }
        return false;
    }

    /// <summary>Empties spotdl's private temp folder (half-downloaded audio after a cancel).</summary>
    public static void ClearFolder(string folder)
    {
        if (!Directory.Exists(folder)) return;
        foreach (var file in Directory.EnumerateFiles(folder, "*", SearchOption.AllDirectories)) DeleteWithRetry(file);
    }
}

/// <summary>The remembered destination, in the data dir's settings.json.</summary>
public static class Settings
{
    public static string? LoadDestination(string file)
    {
        try
        {
            return JsonNode.Parse(File.ReadAllText(file))?["destination"]?.GetValue<string>();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException)
        {
            return null;
        }
    }

    public static void SaveDestination(string file, string destination)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            File.WriteAllText(file, new JsonObject { ["destination"] = destination }.ToJsonString());
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
