using System.Runtime.InteropServices;
using PodFill.Core;

namespace PodFill.Tests;

/// <summary>Ported from the Mac app's PodFillSelfCheck, plus replays of the real fixtures through the view model.</summary>
public class OutputParserTests
{
    internal static string[] Fixture(string name) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "fixtures", name)).Split('\n');

    [Theory]
    [InlineData("Radiohead - Airbag: Searching for song", SongState.Searching)]
    [InlineData("Radiohead - Airbag: Getting audio meta", SongState.Searching)]
    [InlineData("Radiohead - Airbag: Downloading", SongState.Downloading)]
    [InlineData("Radiohead - Airbag: Embedding metadata", SongState.Tagging)]
    [InlineData("Radiohead - Airbag: Done", SongState.Done)]
    [InlineData("Radiohead - Airbag: Skipped", SongState.AlreadyHad)]
    public void SongStatusLines(string line, SongState state) =>
        Assert.Equal(new OutputEvent.Song("Radiohead - Airbag", new SongStatus(state)), OutputParser.Parse(line));

    [Fact]
    public void TitleContainingColonIsNotSplit() =>
        Assert.Equal(new OutputEvent.Song("Artist - Part 1: The Start", SongStatus.Done), OutputParser.Parse("Artist - Part 1: The Start: Done"));

    [Fact]
    public void ErrorStatusLine() =>
        Assert.Equal(new OutputEvent.Song("A - B", SongStatus.Failed("Error")), OutputParser.Parse("A - B: Error"));

    [Fact]
    public void FoundAndProgressLines()
    {
        Assert.Equal(new OutputEvent.Found(12, "OK Computer"), OutputParser.Parse("Found 12 songs in OK Computer (Album)"));
        Assert.Equal(new OutputEvent.Progress(3, 12), OutputParser.Parse("3/12 complete"));
        Assert.Equal(new OutputEvent.Found(50, "Today’s Top Hits"), OutputParser.Parse("Found 50 songs in Today’s Top Hits (Playlist)"));
        Assert.Equal(new OutputEvent.Found(1, "Été (Playlist) 2026"), OutputParser.Parse("Found 1 song in Été (Playlist) 2026 (Playlist)"));
    }

    [Theory]
    [InlineData("Processing query: https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8")]
    [InlineData("Downloaded \"Radiohead - Airbag\": https://music.youtube.com/watch?v=jNY_wLukVW0")]
    [InlineData("Skipping Radiohead - Fitter Happier (file already exists) (duplicate)")]
    [InlineData("Error")]
    [InlineData("")]
    [InlineData("      ")]
    public void NoiseIsIgnored(string line) => Assert.IsType<OutputEvent.Ignored>(OutputParser.Parse(line));

    [Fact]
    public void PaddedLinesAreTrimmed() =>
        Assert.Equal(new OutputEvent.Progress(1, 3), OutputParser.Parse("1/3 complete" + new string(' ', 900) + "\r"));

    [Fact]
    public void FfmpegErrorFromRealRun()
    {
        // Real line from a failed run (empty {list-name} made the output path "/Artist - Title.mp3").
        var ev = Assert.IsType<OutputEvent.Error>(OutputParser.Parse("FFmpegError: Failed to convert Rick Astley - Never Gonna Give You Up, you can find error here:"));
        Assert.Equal("FFmpegError", ev.Kind);
        Assert.Equal("Rick Astley - Never Gonna Give You Up",
                     OutputParser.SongMentionedIn(ev.Message, ["Rick Astley - Never Gonna Give You Up", "Other - Song", "Rick Astley - Never"]));
        Assert.Equal("ffmpeg could not convert the audio", OutputParser.Reason(ev.Kind, ev.Message));
    }

    [Fact]
    public void LookupErrorFormat()
    {
        // Format taken from spotdl's source (logger.error("%s: %s", cls, msg)); not captured live.
        Assert.Equal(new OutputEvent.Error("LookupError", "No results found for song: Artist - Title"),
                     OutputParser.Parse("LookupError: No results found for song: Artist - Title"));
        Assert.Equal("No matching audio found on YouTube Music", OutputParser.Reason("LookupError", ""));
        Assert.Equal("KeyError: x", OutputParser.Reason("KeyError", "x"));
    }

    [Fact]
    public void RealThreeTrackAlbumRun()
    {
        var replay = Replay.Of("album-three-tracks.raw.txt");
        Assert.Equal(new Dictionary<string, SongStatus>
        {
            ["Radiohead - Fitter Happier"] = SongStatus.Done,
            ["Radiohead - No Surprises"] = SongStatus.Done,
            ["Radiohead - Electioneering"] = SongStatus.Done,
        }, replay.Statuses);
        Assert.Equal((3, 3), replay.Progress);
    }

    [Fact]
    public void RealRunWithSkippedAndPaddedLines()
    {
        // Captured with COLUMNS=1000, so every line is padded with trailing spaces.
        var replay = Replay.Of("album-skip-and-download.raw.txt");
        Assert.Equal(12, replay.Total);
        Assert.Equal(SongStatus.AlreadyHad, replay.Statuses["Radiohead - Fitter Happier"]);
        Assert.Equal(SongStatus.Done, replay.Statuses["Radiohead - Airbag"]);
        Assert.Equal(SongStatus.Downloading, replay.Statuses["Radiohead - Let Down"]);   // run was killed mid-download
    }

    [Fact]
    public void RealFfmpegFailureRun()
    {
        var replay = Replay.Of("track-ffmpeg-error.raw.txt");
        Assert.Equal(["FFmpegError"], replay.Errors);
        Assert.Equal(1, replay.Progress?.Done);
    }

    // The same fixtures through the app's view model (the code the window and the CLI run).

    private static MainViewModel NewModel()
    {
        var dir = Path.Combine(Path.GetTempPath(), "podfill-tests-" + Guid.NewGuid().ToString("N"));
        return new MainViewModel(new AppPlatform(OSKind.Windows, Architecture.X64, @"C:\Users\you", @"C:\Users\you\AppData\Local", dir));
    }

    [Fact]
    public void ModelCountsAlbumProgressAndSkips()
    {
        var vm = NewModel();
        vm.ReplayOutput(Fixture("album-skip-and-download.raw.txt"));
        Assert.Equal(12, vm.OverallTotal);
        Assert.Equal(4, vm.OverallDone);
        Assert.Equal("4 of 12", vm.ProgressText);
        Assert.Equal(7, vm.Songs.Count);
        Assert.Equal("Already had it", vm.Songs.Single(s => s.Name == "Radiohead - Fitter Happier").Label);
        Assert.True(vm.Songs.Single(s => s.Name == "Radiohead - Let Down").IsActive);
    }

    [Fact]
    public void ModelPinsFfmpegErrorOnTheSong()
    {
        var vm = NewModel();
        vm.ReplayOutput(Fixture("track-ffmpeg-error.raw.txt"));
        var song = Assert.Single(vm.Songs);
        Assert.Equal(SongStatus.Failed("ffmpeg could not convert the audio"), song.Status);
        Assert.Equal(1, vm.OverallTotal);   // track job: no "Found" line, counted as songs appear
    }

    [Fact]
    public void ModelNeverMovesASongBackwards()
    {
        var vm = NewModel();
        vm.ReplayOutput(["A - B: Downloading", "A - B: Done", "A - B: Searching for song"]);
        Assert.Equal(SongStatus.Done, Assert.Single(vm.Songs).Status);
    }

    private sealed class Replay
    {
        public Dictionary<string, SongStatus> Statuses { get; } = [];
        public (int Done, int Total)? Progress { get; private set; }
        public int? Total { get; private set; }
        public List<string> Errors { get; } = [];

        public static Replay Of(string fixture)
        {
            var r = new Replay();
            foreach (var line in Fixture(fixture))
            {
                switch (OutputParser.Parse(line))
                {
                    case OutputEvent.Song s: r.Statuses[s.Name] = s.Status; break;
                    case OutputEvent.Progress p: r.Progress = (p.Done, p.Total); break;
                    case OutputEvent.Found f: r.Total = f.Count; break;
                    case OutputEvent.Error e: r.Errors.Add(e.Kind); break;
                }
            }
            return r;
        }
    }
}
