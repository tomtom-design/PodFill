using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace PodFill.Core;

/// <summary>
/// The app's state and actions (a port of the Mac app's DownloadModel). No UI framework types: the Avalonia window
/// binds to it, and the CLI harness drives the very same methods headless.
/// All state changes happen on the SynchronizationContext the model was created on (the UI thread).
/// </summary>
public sealed partial class MainViewModel : ObservableObject
{
    private readonly AppPlatform _platform;
    private readonly AppPaths _paths;
    private readonly CommandRunner _runner;
    private readonly SetupService _setup;
    private readonly SynchronizationContext? _ui;
    private readonly int _uiThreadId;
    private readonly StringBuilder _log = new();
    private bool _logFlushPending;
    private bool _cancelled;
    private DateTime _startedUtc;

    public MainViewModel(AppPlatform platform, SetupService? setup = null)
    {
        _platform = platform;
        _paths = new AppPaths(platform);
        _runner = new CommandRunner(_paths);
        _setup = setup ?? new SetupService(_paths);
        _ui = SynchronizationContext.Current;
        _uiThreadId = Environment.CurrentManagedThreadId;
        _destination = Settings.LoadDestination(_paths.SettingsFile) ?? platform.DefaultDestination;
        _needsSetup = !_setup.IsReady;

        DownloadCommand = new RelayCommand(() => _ = StartAsync(), () => CanDownload);
        CancelCommand = new RelayCommand(Cancel, () => IsRunning);
        UpdateCommand = new RelayCommand(() => _ = UpdateDownloaderAsync(), () => !IsBusy && !NeedsSetup);
        SetUpCommand = new RelayCommand(() => _ = SetUpAsync(), () => !IsBusy);
        RevealCommand = new RelayCommand(Reveal);
        Songs.CollectionChanged += (_, _) => Raise(nameof(HasSongs));
    }

    public AppPaths Paths => _paths;

    // MARK: Inputs

    private string _urlText = "";
    public string UrlText
    {
        get => _urlText;
        set { if (Set(ref _urlText, value)) StateChanged(); }
    }

    private string _destination;
    public string Destination
    {
        get => _destination;
        set
        {
            if (string.IsNullOrWhiteSpace(value) || !Set(ref _destination, value)) return;
            Settings.SaveDestination(_paths.SettingsFile, value);
        }
    }

    // MARK: State

    public ObservableCollection<SongRow> Songs { get; } = [];
    public bool HasSongs => Songs.Count > 0;

    private int _overallDone, _overallTotal;
    public int OverallDone { get => _overallDone; private set { if (Set(ref _overallDone, value)) ProgressChanged(); } }
    public int OverallTotal { get => _overallTotal; private set { if (Set(ref _overallTotal, value)) ProgressChanged(); } }
    public bool HasTotal => OverallTotal > 0;
    public string ProgressText => HasTotal ? $"{OverallDone} of {OverallTotal}" : "Reading Spotify…";
    public bool ShowProgress => IsRunning || Finished;

    private string _logText = "";
    public string Log { get => _logText; private set => Set(ref _logText, value); }

    private string? _notice;
    /// <summary>A problem or hint, shown in orange above the progress.</summary>
    public string? Notice { get => _notice; private set { if (Set(ref _notice, value)) Raise(nameof(HasNotice)); } }
    public bool HasNotice => !string.IsNullOrEmpty(Notice);

    private string? _info;
    /// <summary>A neutral status line (setup finished, downloader updated).</summary>
    public string? Info { get => _info; private set { if (Set(ref _info, value)) Raise(nameof(HasInfo)); } }
    public bool HasInfo => !string.IsNullOrEmpty(Info);

    private bool _isRunning, _isUpdating, _isSettingUp, _finished, _showLog, _needsSetup;
    public bool IsRunning { get => _isRunning; private set { if (Set(ref _isRunning, value)) StateChanged(); } }
    public bool IsUpdating { get => _isUpdating; private set { if (Set(ref _isUpdating, value)) StateChanged(); } }
    public bool IsSettingUp { get => _isSettingUp; private set { if (Set(ref _isSettingUp, value)) StateChanged(); } }
    public bool Finished { get => _finished; private set { if (Set(ref _finished, value)) StateChanged(); } }
    public bool ShowLog { get => _showLog; set => Set(ref _showLog, value); }
    public bool NeedsSetup { get => _needsSetup; private set { if (Set(ref _needsSetup, value)) StateChanged(); } }
    public bool IsBusy => IsRunning || IsUpdating || IsSettingUp;
    public bool IsIdle => !IsRunning;

    private string _setupStep = "";
    private double _setupPercent;
    private bool _setupIndeterminate = true;
    public string SetupStep { get => _setupStep; private set => Set(ref _setupStep, value); }
    public double SetupPercent { get => _setupPercent; private set => Set(ref _setupPercent, value); }
    public bool SetupIndeterminate { get => _setupIndeterminate; private set => Set(ref _setupIndeterminate, value); }

    private IReadOnlyList<string> _newFiles = [];
    public IReadOnlyList<string> NewFiles
    {
        get => _newFiles;
        private set { if (Set(ref _newFiles, value)) Raise(nameof(NewFilesText)); }
    }
    public string NewFilesText => $"{NewFiles.Count} new file{(NewFiles.Count == 1 ? "" : "s")}";

    public string RevealLabel => $"Show in {_platform.FileManagerName}";

    public IReadOnlyList<SpotifyLink> ParsedLinks => SpotifyUrl.Parse(UrlText).Links;
    public bool CanDownload => ParsedLinks.Count > 0 && !NeedsSetup && !IsBusy;

    /// <summary>The download, update or setup in flight (the window waits for it before closing).</summary>
    public Task CurrentWork { get; private set; } = Task.CompletedTask;

    public RelayCommand DownloadCommand { get; }
    public RelayCommand CancelCommand { get; }
    public RelayCommand UpdateCommand { get; }
    public RelayCommand SetUpCommand { get; }
    public RelayCommand RevealCommand { get; }

    private void StateChanged()
    {
        Raise(nameof(IsBusy));
        Raise(nameof(IsIdle));
        Raise(nameof(CanDownload));
        Raise(nameof(ShowProgress));
        DownloadCommand?.NotifyCanExecuteChanged();
        CancelCommand?.NotifyCanExecuteChanged();
        UpdateCommand?.NotifyCanExecuteChanged();
        SetUpCommand?.NotifyCanExecuteChanged();
    }

    private void ProgressChanged()
    {
        Raise(nameof(HasTotal));
        Raise(nameof(ProgressText));
    }

    // MARK: Download

    private sealed class JobState
    {
        public int SongsStart;
        public int Base;     // songs finished in earlier jobs
        public int Total;
    }

    public Task StartAsync()
    {
        var (links, rejected) = SpotifyUrl.Parse(UrlText);
        if (links.Count == 0 || NeedsSetup || IsBusy) return Task.CompletedTask;
        return CurrentWork = RunDownloadAsync(links, rejected);
    }

    private async Task RunDownloadAsync(IReadOnlyList<SpotifyLink> links, IReadOnlyList<string> rejected)
    {
        Songs.Clear();
        OverallDone = 0;
        OverallTotal = 0;
        ClearLog();
        NewFiles = [];
        Info = null;
        Notice = rejected.Count == 0 ? null : $"Skipped, not a Spotify track/album/playlist link: {string.Join(", ", rejected)}";
        _cancelled = false;
        Finished = false;
        IsRunning = true;
        _startedUtc = DateTime.UtcNow;
        var destination = Destination;

        try
        {
            Directory.CreateDirectory(destination);
            var baseCount = 0;
            foreach (var job in SpotdlJob.Plan(links))
            {
                if (_cancelled) break;
                var command = Commands.Download(_paths, job, destination);
                AppendLog($"$ spotdl {string.Join(' ', command.Arguments.Select(Quote))}\n");
                var state = new JobState { SongsStart = Songs.Count, Base = baseCount };
                var status = await RunAsync(command, line => Handle(OutputParser.Parse(line), state));
                if (status != 0 && !_cancelled && !Songs.Skip(state.SongsStart).Any(s => s.Status.IsFinished))
                    Notice = $"spotdl stopped with exit code {status} before downloading anything. See the log.";
                baseCount += state.Total;
                // Anything still marked in progress when the process ended did not finish.
                foreach (var song in Songs.Skip(state.SongsStart).Where(s => !s.Status.IsFinished))
                    song.Status = SongStatus.Failed(_cancelled ? "Cancelled" : "Did not finish");
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Notice = $"Can't write to {destination}: {e.Message}";
        }

        if (_cancelled) await RemovePartialFilesAsync(destination);
        NewFiles = await Task.Run(() => DownloadFiles.CollectNew(destination, _startedUtc));
        IsRunning = false;
        Finished = true;
        FlushLog();
    }

    public void Cancel()
    {
        if (!IsBusy) return;
        _cancelled = true;
        _runner.KillCurrent();
        AppendLog("-- cancelled --\n");
    }

    /// <summary>Window closing: stop whatever runs (the run's own cleanup still happens).</summary>
    public Task ShutdownAsync()
    {
        _cancelled = true;
        _runner.KillCurrent();
        return CurrentWork;
    }

    /// <summary>Tests: feed captured spotdl output through the same event handling as a live run (one job).</summary>
    internal void ReplayOutput(IEnumerable<string> lines)
    {
        var state = new JobState { SongsStart = Songs.Count };
        foreach (var line in lines) Handle(OutputParser.Parse(line), state);
    }

    private void Handle(OutputEvent ev, JobState job)
    {
        switch (ev)
        {
            case OutputEvent.Found f:
                job.Total = f.Count;
                OverallTotal = Math.Max(OverallTotal, job.Base + f.Count);
                break;
            case OutputEvent.Progress p:
                job.Total = p.Total;
                OverallTotal = Math.Max(OverallTotal, job.Base + p.Total);
                OverallDone = job.Base + p.Done;
                break;
            case OutputEvent.Song s:
                var row = Songs.Skip(job.SongsStart).FirstOrDefault(r => r.Name == s.Name);
                if (row is null)
                    Songs.Add(new SongRow(s.Name, s.Status));
                else if (!row.Status.IsFinished)   // never move a song backwards (e.g. a late "Searching" after "Done")
                    row.Status = s.Status;
                // Track URLs print no "Found N songs" line, so count songs as they appear.
                if (job.Total == 0) OverallTotal = Math.Max(OverallTotal, job.Base + Songs.Count - job.SongsStart);
                break;
            case OutputEvent.Error e:
                var open = Songs.Skip(job.SongsStart).Where(r => !r.Status.IsFinished).ToList();
                var reason = OutputParser.Reason(e.Kind, e.Message);
                if (OutputParser.SongMentionedIn(e.Message, open.Select(r => r.Name)) is { } name)
                    open.First(r => r.Name == name).Status = SongStatus.Failed(reason);
                else
                    Notice = reason;
                break;
        }
    }

    /// <summary>Runs one process; every output line goes to the log, the hints and <paramref name="onLine"/> on the UI thread.</summary>
    private async Task<int> RunAsync(ToolCommand command, Action<string>? onLine = null)
    {
        try
        {
            return await _runner.RunAsync(command, line => Post(() =>
            {
                AppendLog(line + "\n");
                Hint(line);
                onLine?.Invoke(line);
            }));
        }
        catch (Exception e)
        {
            var what = Path.GetFileName(command.Executable);
            AppendLog($"Could not start {what}: {e.Message}\n");
            Notice = $"Could not start {what}: {e.Message}. Click Set up to repair.";
            return -1;
        }
    }

    private void Hint(string line)
    {
        var l = line.ToLowerInvariant();
        if (l.Contains("429") || l.Contains("retry after") || l.Contains("rate limit"))
            Notice = "Spotify is rate-limiting spotdl's shared credentials. Wait a while and try again (see README.txt).";
        else if (l.Contains("javascript runtime") || (l.Contains("deno") && l.Contains("warn")))
            Notice = "The YouTube downloader wants its JavaScript runtime (Deno). Click Set up to repair it.";
    }

    // MARK: Files

    private async Task RemovePartialFilesAsync(string destination)
    {
        var unfinished = Songs.Where(s => s.Status == SongStatus.Failed("Cancelled")).Select(s => s.Name).ToList();
        var temp = _paths.SpotdlTemp;
        var removed = await Task.Run(() =>
        {
            var partial = DownloadFiles.PartialFiles(DownloadFiles.CollectNew(destination, _startedUtc), unfinished);
            foreach (var file in partial) DownloadFiles.DeleteWithRetry(file);
            DownloadFiles.ClearFolder(temp);
            return partial;
        });
        foreach (var file in removed) AppendLog($"Removed unfinished file: {file}\n");
    }

    public void Reveal()
    {
        try
        {
            Directory.CreateDirectory(Destination);
            using var _ = Process.Start(_platform.RevealCommand(NewFiles.FirstOrDefault(), Destination));
        }
        catch (Exception e)
        {
            Notice = $"Could not open {_platform.FileManagerName}: {e.Message}";
        }
    }

    // MARK: Update downloader

    [GeneratedRegex(@"^\s*\+\s*([A-Za-z0-9_.\-]+)==(\S+)")]
    private static partial Regex UpgradedPackage();

    public Task UpdateDownloaderAsync()
    {
        if (IsBusy || NeedsSetup) return Task.CompletedTask;
        return CurrentWork = RunUpdateAsync();
    }

    private async Task RunUpdateAsync()
    {
        IsUpdating = true;
        Notice = null;
        Info = null;
        AppendLog("\n== Update downloader ==\n");
        var command = Commands.UpgradeSpotdl(_paths);
        AppendLog($"$ {command.Display}\n");
        var updated = new List<string>();
        var status = await RunAsync(command, line =>
        {
            if (UpgradedPackage().Match(line) is { Success: true } m) updated.Add($"{m.Groups[1].Value} {m.Groups[2].Value}");
        });
        AppendLog("== Update finished ==\n");
        if (status != 0)
            Notice = $"Update failed (exit code {status}). See the log.";
        else
            Info = updated.Count == 0 ? "The downloader is up to date." : $"Updated {string.Join(", ", updated)}.";
        NeedsSetup = !_setup.IsReady;
        IsUpdating = false;
        FlushLog();
    }

    // MARK: Set up

    public Task SetUpAsync()
    {
        if (IsBusy) return Task.CompletedTask;
        return CurrentWork = RunSetUpAsync();
    }

    /// <summary>The result of the last successful setup (the CLI smoke test prints it).</summary>
    public EngineVersions? EngineVersions { get; private set; }

    private async Task RunSetUpAsync()
    {
        IsSettingUp = true;
        Notice = null;
        Info = null;
        ShowLog = true;
        _cancelled = false;
        AppendLog("== Set up ==\n");
        try
        {
            EngineVersions = await _setup.RunAsync(
                _runner,
                line => Post(() => AppendLog(line + "\n")),
                p => Post(() =>
                {
                    SetupStep = $"Step {p.Step} of {p.TotalSteps}: {p.Text}…";
                    SetupIndeterminate = p.Percent is null;
                    SetupPercent = p.Percent ?? 0;
                }));
            Info = $"Ready. spotdl {EngineVersions.Spotdl}, {EngineVersions.Ffmpeg.Split(" Copyright")[0]}.";
            AppendLog("== Set up finished ==\n");
        }
        catch (SetupException e)
        {
            Notice = _cancelled ? "Setup was stopped." : e.Message;
            AppendLog($"Setup stopped: {e.Message}\n");
        }
        catch (Exception e)
        {
            Notice = $"Setup failed: {e.Message}";
            AppendLog(e + "\n");
        }
        finally
        {
            NeedsSetup = !_setup.IsReady;
            IsSettingUp = false;
            FlushLog();
        }
    }

    // MARK: Log

    /// <summary>Appends to the log; the bound text is refreshed at most every 150 ms (a 1000-song playlist logs thousands of lines).</summary>
    private void AppendLog(string s)
    {
        _log.Append(s);
        if (_log.Length > 2_000_000) _log.Remove(0, _log.Length - 1_000_000);
        if (_logFlushPending) return;
        _logFlushPending = true;
        _ = FlushLaterAsync();
    }

    private async Task FlushLaterAsync()
    {
        await Task.Delay(150);
        Post(FlushLog);
    }

    private void FlushLog()
    {
        _logFlushPending = false;
        Log = _log.ToString();
    }

    private void ClearLog()
    {
        _log.Clear();
        FlushLog();
    }

    public string FullLog => _log.ToString();

    /// <summary>Runs on the UI thread: inline when already there (keeps log order), else queued in arrival order.</summary>
    private void Post(Action action)
    {
        if (_ui is null || Environment.CurrentManagedThreadId == _uiThreadId) action();
        else _ui.Post(_ => action(), null);
    }

    private static string Quote(string a) =>
        a.Any(c => char.IsWhiteSpace(c) || c is '{' or '"') ? $"\"{a}\"" : a;
}
