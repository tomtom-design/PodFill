using System.Formats.Tar;
using System.IO.Compression;
using System.Net.Http.Headers;
using System.Security.Cryptography;

namespace PodFill.Core;

public sealed record SetupProgress(int Step, int TotalSteps, string Text, double? Percent = null);

public sealed record EngineVersions(string Uv, string Spotdl, string Ffmpeg, string Deno);

/// <summary>A setup failure with a plain-language message for the user.</summary>
public sealed class SetupException(string message) : Exception(message);

/// <summary>
/// The one-time "Set up" (and repair): uv, spotdl + Python, ffmpeg, Deno, then a version check.
/// Both the app's Set up button and the CLI smoke test (CI on windows-latest) run this class.
/// Every step is skipped when its result is already in place, so running it again is a cheap repair.
/// </summary>
public sealed class SetupService
{
    public const int TotalSteps = 5;
    private readonly AppPaths _paths;
    private readonly HttpClient _http;

    public SetupService(AppPaths paths, HttpClient? http = null)
    {
        _paths = paths;
        _http = http ?? CreateHttpClient();
    }

    public static HttpClient CreateHttpClient()
    {
        var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        http.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("PodFill", "1.0"));
        return http;
    }

    /// <summary>Everything a download needs is installed.</summary>
    public bool IsReady =>
        File.Exists(_paths.Uv) && File.Exists(_paths.Spotdl) && File.Exists(_paths.Ffmpeg) && File.Exists(_paths.Deno);

    public async Task<EngineVersions> RunAsync(CommandRunner runner, Action<string> log, Action<SetupProgress> progress,
                                               CancellationToken ct = default)
    {
        Directory.CreateDirectory(_paths.DataDir);
        Directory.CreateDirectory(_paths.HomeDir);

        // 1. uv
        progress(new(1, TotalSteps, $"Downloading uv {UvRelease.Version}", 0));
        if (await UvIsCurrentAsync(runner))
            log($"uv {UvRelease.Version} is already installed.");
        else
            await InstallUvAsync(log, pct => progress(new(1, TotalSteps, $"Downloading uv {UvRelease.Version}", pct)), ct);

        // 2. spotdl (uv also downloads its private Python). A no-op when it is already installed.
        progress(new(2, TotalSteps, $"Installing spotdl and Python {Commands.PythonVersion}"));
        await RunStepAsync(runner, Commands.InstallSpotdl(_paths), log, "Installing spotdl failed");
        if (!File.Exists(_paths.Spotdl))
            throw new SetupException("uv finished but spotdl is missing. See the log.");

        // 3. ffmpeg, through spotdl's own downloader (it writes home\.spotdl\ffmpeg.exe).
        progress(new(3, TotalSteps, "Downloading ffmpeg"));
        if (File.Exists(_paths.Ffmpeg) && (await runner.CaptureAsync(Commands.FfmpegVersion(_paths))).ExitCode == 0)
        {
            log("ffmpeg is already installed.");
        }
        else
        {
            await RunStepAsync(runner, Commands.DownloadFfmpeg(_paths), log, "Downloading ffmpeg failed");
            if (!File.Exists(_paths.Ffmpeg))
                throw new SetupException("spotdl could not download ffmpeg for this PC. See the log.");
        }

        // 4. Deno: yt-dlp needs a JavaScript runtime for YouTube; spotdl passes its local copy to yt-dlp.
        progress(new(4, TotalSteps, "Downloading Deno (needed by the YouTube downloader)"));
        if (File.Exists(_paths.Deno))
        {
            log("Deno is already installed.");
        }
        else
        {
            await RunStepAsync(runner, Commands.DownloadDeno(_paths), log, "Downloading Deno failed");
            if (!File.Exists(_paths.Deno))
                throw new SetupException("spotdl could not download Deno for this PC. See the log.");
        }

        // 5. Does everything run?
        progress(new(5, TotalSteps, "Checking"));
        var versions = await VerifyAsync(runner, log);
        TryDelete(_paths.DownloadsDir);
        return versions;
    }

    /// <summary>Runs uv, spotdl, ffmpeg and Deno once and returns their versions.</summary>
    public async Task<EngineVersions> VerifyAsync(CommandRunner runner, Action<string> log)
    {
        async Task<string> Version(ToolCommand command, string what)
        {
            log($"$ {command.Display}");
            var (code, output) = await runner.CaptureAsync(command);
            var first = output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                              .FirstOrDefault() ?? "";
            log(first);
            if (code != 0 || first.Length == 0)
                throw new SetupException($"{what} does not run (exit code {code}). Click Set up again.");
            return first;
        }

        var uv = await Version(Commands.UvVersion(_paths), "uv");
        var spotdl = await Version(Commands.SpotdlVersion(_paths), "spotdl");
        var ffmpeg = await Version(Commands.FfmpegVersion(_paths), "ffmpeg");
        var deno = await Version(new ToolCommand(_paths.Deno, ["--version"]), "Deno");
        return new EngineVersions(uv, spotdl, ffmpeg, deno);
    }

    private async Task<bool> UvIsCurrentAsync(CommandRunner runner)
    {
        if (!File.Exists(_paths.Uv)) return false;
        try
        {
            var (code, output) = await runner.CaptureAsync(Commands.UvVersion(_paths));
            return code == 0 && output.StartsWith($"uv {UvRelease.Version} ", StringComparison.Ordinal);
        }
        catch (Exception) { return false; }
    }

    private static async Task RunStepAsync(CommandRunner runner, ToolCommand command, Action<string> log, string failure)
    {
        log($"$ {command.Display}");
        int code;
        try { code = await runner.RunAsync(command, log); }
        catch (Exception e) { throw new SetupException($"{failure}: could not start {Path.GetFileName(command.Executable)} ({e.Message})."); }
        if (code != 0) throw new SetupException($"{failure} (exit code {code}). See the log.");
    }

    /// <summary>Downloads the pinned uv archive, checks it against the published .sha256 and the built-in pin, and unpacks uv into the data dir.</summary>
    internal async Task InstallUvAsync(Action<string> log, Action<double> percent, CancellationToken ct)
    {
        var asset = _paths.Platform.UvAsset;
        Directory.CreateDirectory(_paths.DownloadsDir);
        var archive = Path.Combine(_paths.DownloadsDir, asset.Name);
        try
        {
            log($"Downloading {asset.ChecksumUrl}");
            var published = UvRelease.ParseChecksumFile(await _http.GetStringAsync(asset.ChecksumUrl, ct));
            if (published != asset.Sha256)
                throw new SetupException("The published uv checksum does not match the one built into PodFill. Setup stopped for safety.");

            log($"Downloading {asset.Url}");
            await DownloadFileAsync(asset.Url, archive, percent, ct);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            throw new SetupException($"Could not download uv. Check the internet connection and try again. ({e.Message})");
        }

        var actual = await Sha256OfFileAsync(archive, ct);
        log($"sha256 {actual} (published and pinned: {asset.Sha256})");
        if (actual != asset.Sha256)
        {
            File.Delete(archive);
            throw new SetupException("The uv download is damaged (checksum mismatch). Click Set up to try again.");
        }

        var staging = Path.Combine(_paths.DownloadsDir, "uv-extract");
        TryDelete(staging);
        Directory.CreateDirectory(staging);
        await Task.Run(() => Extract(archive, staging, asset.IsZip), ct);

        // Windows zips hold uv.exe at the root; macOS tarballs hold uv-<target>/uv.
        var exe = _paths.Platform.Executable("uv");
        var found = Directory.EnumerateFiles(staging, exe, SearchOption.AllDirectories).FirstOrDefault()
                    ?? throw new SetupException("The uv download did not contain uv.");
        TryDelete(_paths.UvDir);
        Directory.CreateDirectory(_paths.UvDir);
        foreach (var file in Directory.EnumerateFiles(Path.GetDirectoryName(found)!))
        {
            var target = Path.Combine(_paths.UvDir, Path.GetFileName(file));
            File.Move(file, target, overwrite: true);
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(target, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute |
                                             UnixFileMode.GroupRead | UnixFileMode.GroupExecute |
                                             UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
            }
        }
        TryDelete(staging);
        File.Delete(archive);
        log($"uv {UvRelease.Version} installed in {_paths.UvDir}");
    }

    internal static void Extract(string archive, string destination, bool isZip)
    {
        // Both extractors refuse entries that would land outside the destination. TarFile needs the folder to exist.
        Directory.CreateDirectory(destination);
        if (isZip)
        {
            ZipFile.ExtractToDirectory(archive, destination, overwriteFiles: true);
            return;
        }
        using var file = File.OpenRead(archive);
        using var gzip = new GZipStream(file, CompressionMode.Decompress);
        TarFile.ExtractToDirectory(gzip, destination, overwriteFiles: true);
    }

    private async Task DownloadFileAsync(string url, string path, Action<double> percent, CancellationToken ct)
    {
        using var response = await _http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();
        var total = response.Content.Headers.ContentLength;
        await using var source = await response.Content.ReadAsStreamAsync(ct);
        await using var target = File.Create(path);
        var buffer = new byte[81920];
        long done = 0;
        var lastReported = -1;
        int read;
        while ((read = await source.ReadAsync(buffer, ct)) > 0)
        {
            await target.WriteAsync(buffer.AsMemory(0, read), ct);
            done += read;
            if (total is > 0 && (int)(done * 100 / total.Value) is var pct && pct != lastReported)
            {
                lastReported = pct;
                percent(pct);
            }
        }
    }

    internal static async Task<string> Sha256OfFileAsync(string path, CancellationToken ct = default)
    {
        await using var stream = File.OpenRead(path);
        return Convert.ToHexStringLower(await SHA256.HashDataAsync(stream, ct));
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
