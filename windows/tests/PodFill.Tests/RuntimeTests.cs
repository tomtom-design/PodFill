using System.Diagnostics;
using System.Formats.Tar;
using System.IO.Compression;
using PodFill.Core;

namespace PodFill.Tests;

public sealed class TempDir : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "podfill-tests-" + Guid.NewGuid().ToString("N"), "dir é");
    public TempDir() => Directory.CreateDirectory(Path);
    public string File(string name) => System.IO.Path.Combine(Path, name);
    public void Dispose()
    {
        try { Directory.Delete(System.IO.Path.GetDirectoryName(Path)!, recursive: true); } catch (IOException) { }
    }
}

public class UvDownloadTests
{
    [Fact]
    public void ParsesThePublishedChecksumFile()
    {
        // The exact contents of uv-x86_64-pc-windows-msvc.zip.sha256 from the 0.13.9 release.
        const string published = "edd61f7f5728a56cc62455386661860bdfc7bab65872f39b0c25bdcc1d8e1beb  uv-x86_64-pc-windows-msvc.zip\n";
        Assert.Equal(UvRelease.AssetFor(OSKind.Windows, System.Runtime.InteropServices.Architecture.X64).Sha256, UvRelease.ParseChecksumFile(published));
        Assert.Throws<FormatException>(() => UvRelease.ParseChecksumFile("<html>Not Found</html>"));
        Assert.Throws<FormatException>(() => UvRelease.ParseChecksumFile(""));
    }

    [Fact]
    public async Task HashesFiles()
    {
        using var dir = new TempDir();
        await File.WriteAllTextAsync(dir.File("a.txt"), "abc");
        Assert.Equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", await SetupService.Sha256OfFileAsync(dir.File("a.txt")));
    }

    [Fact]
    public void ExtractsBothArchiveLayouts()
    {
        using var dir = new TempDir();
        // Windows asset: uv.exe at the zip root.
        using (var zip = ZipFile.Open(dir.File("uv.zip"), ZipArchiveMode.Create))
            using (var w = new StreamWriter(zip.CreateEntry("uv.exe").Open())) w.Write("exe");
        SetupService.Extract(dir.File("uv.zip"), dir.File("zip-out"), isZip: true);
        Assert.Equal("exe", File.ReadAllText(System.IO.Path.Combine(dir.File("zip-out"), "uv.exe")));

        // macOS asset: uv-<target>/uv inside a .tar.gz.
        Directory.CreateDirectory(dir.File("src/uv-aarch64-apple-darwin"));
        File.WriteAllText(dir.File("src/uv-aarch64-apple-darwin/uv"), "bin");
        using (var gz = new GZipStream(File.Create(dir.File("uv.tar.gz")), CompressionLevel.Fastest))
            TarFile.CreateFromDirectory(dir.File("src"), gz, includeBaseDirectory: false);
        SetupService.Extract(dir.File("uv.tar.gz"), dir.File("tar-out"), isZip: false);
        Assert.Equal("bin", File.ReadAllText(System.IO.Path.Combine(dir.File("tar-out"), "uv-aarch64-apple-darwin", "uv")));
    }
}

public class DownloadFilesTests
{
    [Fact]
    public void PartialFilesMatchUnfinishedSongsByName()
    {
        var files = new[]
        {
            System.IO.Path.Combine("x", "OK Computer", "Radiohead - Exit Music (For A Film).mp3"),
            System.IO.Path.Combine("x", "OK Computer", "Radiohead - Airbag.mp3"),
            System.IO.Path.Combine("x", "Singles", "AC-DC - Back In Black.mp3"),   // spotdl sanitizes "/" in names
        };
        var partial = DownloadFiles.PartialFiles(files, ["Radiohead - Exit Music (For A Film)", "AC/DC - Back In Black"]);
        Assert.Equal([files[0], files[2]], partial);
    }

    [Fact]
    public void CollectsOnlyMp3sWrittenDuringTheRun()
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(dir.File("List"));
        File.WriteAllText(dir.File("List/old.mp3"), "");
        File.SetLastWriteTimeUtc(dir.File("List/old.mp3"), DateTime.UtcNow.AddDays(-3));
        var start = DateTime.UtcNow;
        File.WriteAllText(dir.File("List/new.MP3"), "");
        File.WriteAllText(dir.File("List/cover.jpg"), "");
        Assert.Equal([System.IO.Path.GetFullPath(dir.File("List/new.MP3"))], DownloadFiles.CollectNew(dir.Path, start).Select(System.IO.Path.GetFullPath));
        Assert.Empty(DownloadFiles.CollectNew(dir.File("missing"), start));
    }

    [Fact]
    public void RemembersTheDestination()
    {
        using var dir = new TempDir();
        Assert.Null(Settings.LoadDestination(dir.File("settings.json")));
        Settings.SaveDestination(dir.File("settings.json"), @"D:\iPod yoü");
        Assert.Equal(@"D:\iPod yoü", Settings.LoadDestination(dir.File("settings.json")));
        File.WriteAllText(dir.File("bad.json"), "{nope");
        Assert.Null(Settings.LoadDestination(dir.File("bad.json")));
    }
}

/// <summary>The real process runner against real child processes (cmd/ping on Windows, sh/sleep elsewhere).</summary>
public class ProcessRunnerTests
{
    private static readonly IReadOnlyDictionary<string, string> Env =
        Environment.GetEnvironmentVariables().Cast<System.Collections.DictionaryEntry>()
                   .ToDictionary(e => (string)e.Key, e => (string)e.Value!);

    private static async Task<(int Code, List<string> Lines)> Run(ToolCommand command)
    {
        var lines = new List<string>();
        var code = await new ProcessRunner().RunAsync(command, Env, lines.Add);
        return (code, lines);
    }

    [Fact]
    public async Task StreamsUtf8LinesFromStdoutAndStderr()
    {
        var command = OperatingSystem.IsWindows()
            ? new ToolCommand("powershell.exe", ["-NoProfile", "-Command",
                "[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding $false; Write-Output 'Zoë – ✓ 東京'; [Console]::Error.WriteLine('to stderr'); exit 3"])
            : new ToolCommand("/bin/sh", ["-c", "printf 'Zoë – ✓ 東京\\n'; printf 'a\\rb\\n'; echo 'to stderr' >&2; exit 3"]);
        var (code, lines) = await Run(command);
        Assert.Equal(3, code);
        Assert.Contains("Zoë – ✓ 東京", lines);
        Assert.Contains("to stderr", lines);
        if (!OperatingSystem.IsWindows()) Assert.Contains("b", lines);   // a lone \r ends a line too
    }

    [Fact]
    public async Task AnswersAPromptOnStdinThenClosesIt()
    {
        var command = OperatingSystem.IsWindows()
            ? new ToolCommand("cmd.exe", ["/v:on", "/c", "set /p x=Overwrite? & echo got !x!"], "y\n")
            : new ToolCommand("/bin/sh", ["-c", "printf 'Overwrite? '; read x; echo \"got $x\"; read y || echo eof"], "y\n");
        var (code, lines) = await Run(command);
        Assert.Equal(0, code);
        Assert.Contains(lines, l => l.EndsWith("got y", StringComparison.Ordinal));
        if (!OperatingSystem.IsWindows()) Assert.Contains("eof", lines);   // stdin is closed: no hang on a second prompt
    }

    [Fact]
    public async Task MissingExecutableThrows() =>
        await Assert.ThrowsAnyAsync<Exception>(() => Run(new ToolCommand(Path.Combine(Path.GetTempPath(), "no-such-tool-" + Guid.NewGuid()), [])));

    /// <summary>Cancel must kill the whole tree: a shell with two sleeping grandchildren stands in for spotdl -> python -> ffmpeg.</summary>
    [Fact]
    public async Task KillTreeKillsGrandchildren()
    {
        var marker = OperatingSystem.IsWindows() ? "PING" : "sleep";
        int Count() => OperatingSystem.IsWindows()
            ? Process.GetProcessesByName("PING").Length
            : CountUnix("sleep 6[12]");
        var before = Count();

        var command = OperatingSystem.IsWindows()
            ? new ToolCommand("cmd.exe", ["/c", "start /b ping -n 61 127.0.0.1 >nul & ping -n 62 127.0.0.1 >nul"])
            : new ToolCommand("/bin/sh", ["-c", "sleep 61 & sleep 62 & wait"]);
        var runner = new ProcessRunner();
        var run = runner.RunAsync(command, Env, _ => { });
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (Count() < before + 2 && DateTime.UtcNow < deadline) await Task.Delay(100);
        Assert.True(Count() >= before + 2, $"two {marker} grandchildren running before cancel");

        runner.KillTree();
        var finished = await Task.WhenAny(run, Task.Delay(TimeSpan.FromSeconds(10)));
        Assert.Same(run, finished);   // the runner returns promptly after a kill
        await Task.Delay(500);
        Assert.Equal(before, Count());
    }

    private static int CountUnix(string pattern)
    {
        using var p = Process.Start(new ProcessStartInfo("/usr/bin/pgrep", ["-f", $"^{pattern}$"]) { RedirectStandardOutput = true })!;
        var output = p.StandardOutput.ReadToEnd();
        p.WaitForExit();
        return output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Length;
    }

    [Fact]
    public void DisplayQuotesArgumentsWithSpacesAndBraces()
    {
        var c = new ToolCommand(@"C:\Users\Your Name\uv.exe", ["tool", @"C:\x\{artist} - {title}.{output-ext}"]);
        Assert.Equal(@"""C:\Users\Your Name\uv.exe"" tool ""C:\x\{artist} - {title}.{output-ext}""", c.Display);
    }
}
