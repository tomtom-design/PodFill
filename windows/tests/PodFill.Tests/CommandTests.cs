using System.Runtime.InteropServices;
using PodFill.Core;

namespace PodFill.Tests;

public class SpotifyUrlTests
{
    [Fact]
    public void ParsesAllKindsAndStripsTracking()
    {
        var (links, rejected) = SpotifyUrl.Parse("""
            https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8?si=abc123
            https://open.spotify.com/intl-fr/album/6dVIqQ8qmQ5GBnJ9shOYGE
            https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M, spotify:track:4PTG3Z6ehGkBFwjybzWkR8
            not a link
            """);
        Assert.Equal([LinkKind.Track, LinkKind.Album, LinkKind.Playlist], links.Select(l => l.Kind));
        Assert.Equal("https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8", links[0].Url);
        Assert.Equal("https://open.spotify.com/album/6dVIqQ8qmQ5GBnJ9shOYGE", links[1].Url);
        Assert.Equal(["not", "a", "link"], rejected);
    }

    [Theory]
    [InlineData("https://example.com/track/4PTG3Z6ehGkBFwjybzWkR8")]
    [InlineData("https://open.spotify.com/artist/4Z8W4fKeB5YxbusRsdQVPb")]
    [InlineData("https://open.spotify.com/track/bad-id!")]
    [InlineData("spotify:show:4PTG3Z6ehGkBFwjybzWkR8")]
    [InlineData(@"C:\Users\you\Music\song.mp3")]
    [InlineData("file:///C:/track/4PTG3Z6ehGkBFwjybzWkR8")]
    public void RejectsWhatSpotdlShouldNotGet(string token) => Assert.Null(SpotifyUrl.LinkFrom(token));

    [Fact]
    public void WindowsLineEndingsAndDuplicates()
    {
        var (links, rejected) = SpotifyUrl.Parse("https://open.spotify.com/track/A1\r\nhttps://open.spotify.com/track/A1?si=x\r\n");
        Assert.Single(links);
        Assert.Empty(rejected);
    }
}

public class SpotdlJobTests
{
    private static IReadOnlyList<SpotdlJob> Jobs(string text) => SpotdlJob.Plan(SpotifyUrl.Parse(text).Links);

    [Fact]
    public void ListsGetOneJobEachAndTracksShareOne()
    {
        var jobs = Jobs("https://open.spotify.com/track/T1 https://open.spotify.com/album/A1 https://open.spotify.com/track/T2 https://open.spotify.com/playlist/P1");
        Assert.Equal(["https://open.spotify.com/album/A1", "https://open.spotify.com/playlist/P1", "2 tracks"], jobs.Select(j => j.Title));
    }

    [Fact]
    public void ArgumentsMatchTheMacApp()
    {
        var album = Jobs("https://open.spotify.com/album/6dVIqQ8qmQ5GBnJ9shOYGE")[0];
        Assert.Equal(
            [
                "download", "https://open.spotify.com/album/6dVIqQ8qmQ5GBnJ9shOYGE",
                "--ffmpeg", @"C:\Users\you\AppData\Local\PodFill\home\.spotdl\ffmpeg.exe",
                "--format", "mp3", "--bitrate", "auto", "--threads", "4", "--overwrite", "skip",
                "--lyrics", "--simple-tui", "--log-level", "INFO",
                "--output", @"C:\Users\you\Music\iPod\{list-name}\{artist} - {title}.{output-ext}",
            ],
            album.Arguments(@"C:\Users\you\AppData\Local\PodFill\home\.spotdl\ffmpeg.exe", @"C:\Users\you\Music\iPod", '\\'));
    }

    [Theory]
    // Windows: drive letters, spaces, trailing separators, a drive root, UNC shares, forward slashes from a picker.
    [InlineData(@"C:\Users\you\Music\iPod", '\\', true, @"C:\Users\you\Music\iPod\{list-name}\{artist} - {title}.{output-ext}")]
    [InlineData(@"C:\Users\you\Music\iPod", '\\', false, @"C:\Users\you\Music\iPod\Singles\{artist} - {title}.{output-ext}")]
    [InlineData(@"C:\Users\Your Name\Music\iPod\", '\\', true, @"C:\Users\Your Name\Music\iPod\{list-name}\{artist} - {title}.{output-ext}")]
    [InlineData(@"D:\", '\\', false, @"D:\Singles\{artist} - {title}.{output-ext}")]
    [InlineData(@"\\NAS\share\iPod", '\\', true, @"\\NAS\share\iPod\{list-name}\{artist} - {title}.{output-ext}")]
    [InlineData(@"C:\Users\yoü\Music\iPod", '\\', true, @"C:\Users\yoü\Music\iPod\{list-name}\{artist} - {title}.{output-ext}")]
    // macOS (the test machine): same as the Mac app.
    [InlineData("/Users/you/Music/iPod", '/', true, "/Users/you/Music/iPod/{list-name}/{artist} - {title}.{output-ext}")]
    [InlineData("/d", '/', false, "/d/Singles/{artist} - {title}.{output-ext}")]
    [InlineData("/", '/', false, "/Singles/{artist} - {title}.{output-ext}")]
    public void OutputTemplate(string destination, char separator, bool list, string expected)
    {
        var job = Jobs(list ? "https://open.spotify.com/playlist/P1" : "https://open.spotify.com/track/T1")[0];
        Assert.Equal(expected, job.OutputTemplate(destination, separator));
        Assert.Equal(expected, job.Arguments("ffmpeg", destination, separator)[^1]);
    }
}

public class PlatformTests
{
    private static AppPlatform Windows(Architecture arch = Architecture.X64, string? overrideDir = null) =>
        new(OSKind.Windows, arch, @"C:\Users\you", @"C:\Users\you\AppData\Local", overrideDir);

    [Fact]
    public void WindowsDataDirLayout()
    {
        var p = new AppPaths(Windows());
        Assert.Equal(@"C:\Users\you\AppData\Local\PodFill", p.DataDir);
        Assert.Equal(@"C:\Users\you\AppData\Local\PodFill\uv\uv.exe", p.Uv);
        Assert.Equal(@"C:\Users\you\AppData\Local\PodFill\bin\spotdl.exe", p.Spotdl);
        Assert.Equal(@"C:\Users\you\AppData\Local\PodFill\home\.spotdl\ffmpeg.exe", p.Ffmpeg);
        Assert.Equal(@"C:\Users\you\AppData\Local\PodFill\home\.spotdl\deno.exe", p.Deno);
        Assert.Equal(@"C:\Users\you\AppData\Local\PodFill\settings.json", p.SettingsFile);
        Assert.Equal(@"C:\Users\you\Music\iPod", p.Platform.DefaultDestination);
        Assert.Equal("USERPROFILE", p.Platform.HomeVariable);
        Assert.Equal("Explorer", p.Platform.FileManagerName);
    }

    [Fact]
    public void DataDirOverride()
    {
        var p = new AppPaths(Windows(overrideDir: @"D:\Temp\PodFill test é"));
        Assert.Equal(@"D:\Temp\PodFill test é\bin\spotdl.exe", p.Spotdl);
        Assert.Equal(@"C:\Users\you\AppData\Local\PodFill", new AppPaths(Windows(overrideDir: "  ")).DataDir);
    }

    [Fact]
    public void MacDataDirLayout()
    {
        var mac = new AppPlatform(OSKind.MacOS, Architecture.Arm64, "/Users/you", "/Users/you/Library/Application Support", null);
        var p = new AppPaths(mac);
        Assert.Equal("/Users/you/Library/Application Support/PodFill/bin/spotdl", p.Spotdl);
        Assert.Equal("/Users/you/Library/Application Support/PodFill/home/.spotdl/ffmpeg", p.Ffmpeg);
        Assert.Equal("/Users/you/Music/iPod", mac.DefaultDestination);
        Assert.Equal("HOME", mac.HomeVariable);
    }

    [Theory]
    [InlineData(OSKind.Windows, Architecture.X64, "uv-x86_64-pc-windows-msvc.zip", true)]
    [InlineData(OSKind.Windows, Architecture.Arm64, "uv-aarch64-pc-windows-msvc.zip", true)]
    [InlineData(OSKind.MacOS, Architecture.Arm64, "uv-aarch64-apple-darwin.tar.gz", false)]
    [InlineData(OSKind.MacOS, Architecture.X64, "uv-x86_64-apple-darwin.tar.gz", false)]
    public void UvAssetPerMachine(OSKind os, Architecture arch, string name, bool zip)
    {
        var asset = UvRelease.AssetFor(os, arch);
        Assert.Equal(name, asset.Name);
        Assert.Equal(zip, asset.IsZip);
        Assert.Equal($"https://github.com/astral-sh/uv/releases/download/0.13.9/{name}", asset.Url);
        Assert.Equal(asset.Url + ".sha256", asset.ChecksumUrl);
        Assert.Matches("^[0-9a-f]{64}$", asset.Sha256);
    }

    [Fact]
    public void UnsupportedMachineSaysSo() =>
        Assert.Throws<PlatformNotSupportedException>(() => UvRelease.AssetFor(OSKind.Windows, Architecture.X86));

    [Fact]
    public void RevealSelectsTheFileInExplorer()
    {
        var psi = Windows().RevealCommand(@"C:\Users\you\Music\iPod\Singles\A - B.mp3", @"C:\Users\you\Music\iPod");
        Assert.Equal("explorer.exe", psi.FileName);
        Assert.Equal(@"/select,""C:\Users\you\Music\iPod\Singles\A - B.mp3""", psi.Arguments);
        Assert.Equal(@"""C:\Users\you\Music\iPod""", Windows().RevealCommand(null, @"C:\Users\you\Music\iPod").Arguments);
    }

    [Fact]
    public void ChildEnvironmentIsolatesEverythingInTheDataDir()
    {
        var p = new AppPaths(Windows());
        var env = p.ChildEnvironment(new System.Collections.Hashtable
        {
            ["Path"] = @"C:\Windows\system32;C:\Python313",
            ["SystemRoot"] = @"C:\Windows",
            ["USERPROFILE"] = @"C:\Users\you",
            ["HTTPS_PROXY"] = "http://proxy:8080",
            ["uv_index_url"] = "https://example.com/simple",   // Windows names are case-insensitive
            ["UV_TOOL_DIR"] = @"C:\elsewhere",
            ["VIRTUAL_ENV"] = @"C:\venv",
            ["PythonPath"] = @"C:\lib",
        });
        Assert.Equal(@"C:\Windows\system32;C:\Python313", env["PATH"]);
        Assert.Equal(@"C:\Windows", env["SystemRoot"]);
        Assert.Equal("http://proxy:8080", env["HTTPS_PROXY"]);
        Assert.False(env.ContainsKey("UV_INDEX_URL"));
        Assert.False(env.ContainsKey("VIRTUAL_ENV"));
        Assert.False(env.ContainsKey("PYTHONPATH"));
        Assert.Equal(@"C:\Users\you\AppData\Local\PodFill\home", env["USERPROFILE"]);   // spotdl's ~/.spotdl -> data dir
        Assert.Equal("utf-8", env["PYTHONIOENCODING"]);
        Assert.Equal("1", env["PYTHONUTF8"]);
        Assert.Equal("1", env["PYTHONUNBUFFERED"]);
        Assert.Equal("1000", env["COLUMNS"]);
        Assert.Equal("1", env["NO_COLOR"]);
        Assert.Equal("1", env["UV_MANAGED_PYTHON"]);
        Assert.Equal("0", env["UV_PYTHON_INSTALL_REGISTRY"]);
        foreach (var key in new[] { "UV_TOOL_DIR", "UV_TOOL_BIN_DIR", "UV_PYTHON_INSTALL_DIR", "UV_PYTHON_BIN_DIR", "UV_CACHE_DIR", "DENO_DIR" })
            Assert.StartsWith(@"C:\Users\you\AppData\Local\PodFill\", env[key]);
    }

    [Fact]
    public void ExactEngineCommands()
    {
        var p = new AppPaths(Windows());
        Assert.Equal(@"C:\Users\you\AppData\Local\PodFill\uv\uv.exe tool install spotdl>=4.6,<5 --python 3.13", Commands.InstallSpotdl(p).Display);
        Assert.Equal(@"C:\Users\you\AppData\Local\PodFill\uv\uv.exe tool upgrade spotdl", Commands.UpgradeSpotdl(p).Display);
        Assert.Equal(["--download-ffmpeg"], Commands.DownloadFfmpeg(p).Arguments);
        Assert.Equal("y\n", Commands.DownloadFfmpeg(p).StandardInput);
        Assert.Equal("y\n", Commands.DownloadDeno(p).StandardInput);
        var download = Commands.Download(p, SpotdlJob.Plan(SpotifyUrl.Parse("https://open.spotify.com/track/T1").Links)[0], @"C:\Users\you\Music\iPod");
        Assert.Equal(p.Spotdl, download.Executable);
        Assert.Equal(p.Ffmpeg, download.Arguments[download.Arguments.ToList().IndexOf("--ffmpeg") + 1]);
    }
}
