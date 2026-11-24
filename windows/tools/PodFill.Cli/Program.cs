using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using PodFill.Core;

// podfill-cli: runs the app's MainViewModel headless, on a single-threaded SynchronizationContext just like the
// UI thread. Set PODFILL_DATA_DIR to keep everything in a throwaway folder.
//
//   podfill-cli setup                                   Set up (same as the button) + print the engine versions
//   podfill-cli update                                  Update downloader (uv tool upgrade spotdl)
//   podfill-cli command --dest DIR URL...               print the exact spotdl commands
//   podfill-cli download --dest DIR URL...              Download, then print the per-song result
//   podfill-cli cancel --dest DIR [--after S] URL...    Download, Cancel S seconds after the first "Downloading",
//                                                       then check that no spotdl/python/ffmpeg process survived
Console.OutputEncoding = new System.Text.UTF8Encoding(false);   // song names and data-dir paths are Unicode
var command = args.FirstOrDefault() ?? "";
string? dest = null;
var afterSeconds = 2.0;
var urls = new List<string>();
for (var i = 1; i < args.Length; i++)
{
    if (args[i] == "--dest" && i + 1 < args.Length) dest = args[++i];
    else if (args[i] == "--after" && i + 1 < args.Length) afterSeconds = double.Parse(args[++i], System.Globalization.CultureInfo.InvariantCulture);
    else urls.Add(args[i]);
}

if (command is not ("setup" or "update" or "command" or "download" or "cancel")
    || (command is "command" or "download" or "cancel" && (dest is null || urls.Count == 0)))
{
    Console.Error.WriteLine("usage: podfill-cli setup | update | command|download|cancel --dest DIR [--after S] URL...");
    return 2;
}

var platform = AppPlatform.Current;
Console.WriteLine($"data dir: {platform.DataDir}");

if (command == "command")
{
    var paths = new AppPaths(platform);
    foreach (var job in SpotdlJob.Plan(SpotifyUrl.Parse(string.Join(' ', urls)).Links))
        Console.WriteLine(Commands.Download(paths, job, Path.GetFullPath(dest!)).Display);
    Console.WriteLine(Commands.InstallSpotdl(paths).Display);
    Console.WriteLine(Commands.UpgradeSpotdl(paths).Display);
    Console.WriteLine(Commands.DownloadFfmpeg(paths).Display + "   (stdin: y)");
    Console.WriteLine(Commands.DownloadDeno(paths).Display + "   (stdin: y)");
    var env = new CommandRunner(paths).Environment;
    foreach (var key in env.Keys.Where(k => k.StartsWith("UV_") || k.StartsWith("PYTHON") || k.StartsWith("DENO") ||
                                            k is "HOME" or "USERPROFILE" or "COLUMNS" or "NO_COLOR").Order())
        Console.WriteLine($"  {key}={env[key]}");
    return 0;
}

return SingleThreadContext.Run(async () =>
{
    var vm = new MainViewModel(platform);
    var printed = 0;
    vm.PropertyChanged += (_, e) =>
    {
        if (e.PropertyName != nameof(MainViewModel.Log)) return;
        var log = vm.Log;
        if (log.Length < printed) printed = 0;
        Console.Write(log[printed..]);
        printed = log.Length;
    };

    switch (command)
    {
        case "setup":
            await vm.SetUpAsync();
            Report(vm);
            if (vm.NeedsSetup || vm.EngineVersions is not { } v) return 1;
            Console.WriteLine($"uv:     {v.Uv}\nspotdl: {v.Spotdl}\nffmpeg: {v.Ffmpeg}\ndeno:   {v.Deno}");
            Console.WriteLine($"ffmpeg path passed to spotdl --ffmpeg: {vm.Paths.Ffmpeg}");
            return 0;

        case "update":
            if (vm.NeedsSetup) { Console.Error.WriteLine("not set up"); return 1; }
            await vm.UpdateDownloaderAsync();
            Report(vm);
            return vm.HasNotice ? 1 : 0;

        case "download":
            vm.UrlText = string.Join('\n', urls);
            vm.Destination = Path.GetFullPath(dest!);
            if (!vm.CanDownload) { Console.Error.WriteLine("cannot download (not set up, or no valid link)"); return 1; }
            await vm.StartAsync();
            Report(vm);
            return vm.Songs.Count > 0 && vm.Songs.All(s => s.IsDone || s.IsAlreadyHad) ? 0 : 1;

        default: // cancel
            vm.UrlText = string.Join('\n', urls);
            vm.Destination = Path.GetFullPath(dest!);
            if (!vm.CanDownload) { Console.Error.WriteLine("cannot download"); return 1; }
            var work = vm.StartAsync();
            var started = Stopwatch.StartNew();
            DateTime? firstDownload = null;
            List<string> treeBeforeCancel = [];
            while (!work.IsCompleted)
            {
                if (firstDownload is null && vm.Songs.Any(s => s.Status.State >= SongState.Downloading)) firstDownload = DateTime.UtcNow;
                if ((firstDownload is { } t && DateTime.UtcNow - t > TimeSpan.FromSeconds(afterSeconds)) || started.Elapsed > TimeSpan.FromMinutes(3))
                {
                    treeBeforeCancel = ProcessesUnder(platform.DataDir);
                    Console.WriteLine($"\n>>> CANCEL at {started.Elapsed.TotalSeconds:F1}s; processes running from the data dir:");
                    foreach (var p in treeBeforeCancel) Console.WriteLine($"    {p}");
                    vm.Cancel();
                    break;
                }
                await Task.Delay(100);
            }
            var cancelAt = started.Elapsed;
            await work;
            Console.WriteLine($">>> run returned {(started.Elapsed - cancelAt).TotalSeconds:F1}s after Cancel");
            await Task.Delay(1000);
            var survivors = ProcessesUnder(platform.DataDir);
            Report(vm);
            Console.WriteLine($">>> processes from the data dir 1 s after the run returned: {survivors.Count}");
            foreach (var p in survivors) Console.WriteLine($"    {p}");
            return treeBeforeCancel.Count > 0 && survivors.Count == 0 ? 0 : 1;
    }
});

static void Report(MainViewModel vm)
{
    Console.WriteLine("\n--- result ---");
    if (vm.HasNotice) Console.WriteLine($"notice: {vm.Notice}");
    if (vm.HasInfo) Console.WriteLine($"info:   {vm.Info}");
    if (vm.OverallTotal > 0) Console.WriteLine($"progress: {vm.ProgressText}");
    foreach (var s in vm.Songs) Console.WriteLine($"  [{s.Label}] {s.Name}");
    if (vm.Finished) Console.WriteLine($"{vm.NewFilesText}:");
    foreach (var f in vm.NewFiles) Console.WriteLine($"  {f}");
}

/// <summary>Processes whose executable or command line lives in the data dir (uv, spotdl, python, ffmpeg, deno).</summary>
static List<string> ProcessesUnder(string dataDir)
{
    if (OperatingSystem.IsWindows())
    {
        var found = new List<string>();
        foreach (var p in Process.GetProcesses())
        {
            try
            {
                var file = p.MainModule?.FileName;
                if (file is not null && file.StartsWith(dataDir, StringComparison.OrdinalIgnoreCase)) found.Add($"{p.Id} {file}");
            }
            catch (Exception e) when (e is Win32Exception or InvalidOperationException) { }
            finally { p.Dispose(); }
        }
        return found;
    }
    var ps = Process.Start(new ProcessStartInfo("ps", ["-axww", "-o", "pid=,ppid=,command="]) { RedirectStandardOutput = true })!;
    var lines = ps.StandardOutput.ReadToEnd().Split('\n');
    ps.WaitForExit();
    return lines.Where(l => l.Contains(dataDir, StringComparison.Ordinal) && !l.Contains("podfill-cli"))
                .Select(l => l.Trim().Length > 200 ? l.Trim()[..200] + "..." : l.Trim())
                .ToList();
}

/// <summary>A single-threaded SynchronizationContext (like a UI thread): every continuation and posted callback runs on this thread.</summary>
sealed class SingleThreadContext : SynchronizationContext
{
    private readonly BlockingCollection<(SendOrPostCallback Callback, object? State)> _queue = new();

    public override void Post(SendOrPostCallback d, object? state)
    {
        try { _queue.Add((d, state)); }
        catch (InvalidOperationException) { /* late callback after the run finished */ }
    }

    public override void Send(SendOrPostCallback d, object? state) => throw new NotSupportedException();

    public static int Run(Func<Task<int>> body)
    {
        var previous = Current;
        var context = new SingleThreadContext();
        SetSynchronizationContext(context);
        try
        {
            var task = body();
            task.ContinueWith(_ => context._queue.CompleteAdding(), TaskScheduler.Default);
            foreach (var (callback, state) in context._queue.GetConsumingEnumerable()) callback(state);
            return task.GetAwaiter().GetResult();
        }
        finally
        {
            SetSynchronizationContext(previous);
        }
    }
}
