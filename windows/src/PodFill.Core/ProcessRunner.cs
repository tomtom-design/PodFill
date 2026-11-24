using System.Collections;
using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace PodFill.Core;

/// <summary>One command line. <paramref name="StandardInput"/> is written to the child's stdin, which is then closed.</summary>
public sealed record ToolCommand(string Executable, IReadOnlyList<string> Arguments, string? StandardInput = null)
{
    /// <summary>For the log: the command with arguments quoted where needed.</summary>
    public string Display =>
        string.Join(' ', new[] { Executable }.Concat(Arguments).Select(a =>
            a.Length == 0 || a.Any(c => char.IsWhiteSpace(c) || c is '"' or '{' or '\'') ? $"\"{a}\"" : a));
}

/// <summary>Runs a child process, streams stdout and stderr line by line, and can kill the whole process tree.</summary>
public sealed class ProcessRunner
{
    private static readonly Encoding Utf8 = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
    private readonly object _lineLock = new();
    private Process? _process;
    private volatile bool _killed;

    public int? ProcessId { get; private set; }

    /// <summary>
    /// Starts the process and returns its exit code once it has finished and its output has been read.
    /// The pipes are read on thread-pool threads (ConfigureAwait(false)), never on the caller's UI thread.
    /// <paramref name="onLine"/> is called on a background thread, never concurrently.
    /// </summary>
    public async Task<int> RunAsync(ToolCommand command, IReadOnlyDictionary<string, string> environment,
                                    Action<string> onLine, string? workingDirectory = null)
    {
        var psi = new ProcessStartInfo(command.Executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,          // no console window flashing up on Windows
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Utf8,
            StandardErrorEncoding = Utf8,
            StandardInputEncoding = Utf8,
        };
        if (workingDirectory is not null) psi.WorkingDirectory = workingDirectory;
        foreach (var a in command.Arguments) psi.ArgumentList.Add(a);   // .NET quotes each argument for the Windows command line
        psi.Environment.Clear();
        foreach (var (k, v) in environment) psi.Environment[k] = v;

        using var process = new Process { StartInfo = psi };
        process.Start();   // throws Win32Exception if the executable is missing
        _process = process;
        ProcessId = process.Id;
        if (_killed) KillTree();   // cancelled while starting

        // Never let a prompt block on stdin: write the canned answer (if any) and close it.
        try
        {
            if (command.StandardInput is not null) await process.StandardInput.WriteAsync(command.StandardInput).ConfigureAwait(false);
            process.StandardInput.Close();
        }
        catch (IOException) { /* the child exited before reading stdin */ }

        var stdout = PumpAsync(process.StandardOutput, onLine);
        var stderr = PumpAsync(process.StandardError, onLine);
        await process.WaitForExitAsync().ConfigureAwait(false);
        // A grandchild that outlived the parent can keep the pipes open; don't wait for it forever.
        await Task.WhenAny(Task.WhenAll(stdout, stderr), Task.Delay(TimeSpan.FromSeconds(5))).ConfigureAwait(false);
        _process = null;
        return process.ExitCode;
    }

    private async Task PumpAsync(StreamReader reader, Action<string> onLine)
    {
        try
        {
            // ReadLineAsync splits on \n, \r\n and a lone \r, so progress-style output streams too.
            while (await reader.ReadLineAsync().ConfigureAwait(false) is { } line)
            {
                if (line.Length == 0) continue;
                lock (_lineLock) onLine(line);
            }
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException) { }
    }

    /// <summary>
    /// Kills the process and every descendant. spotdl spawns ffmpeg (and yt-dlp runs Deno); killing only the parent
    /// would leave ffmpeg running and writing files. On Windows the tree is spotdl.exe (uv launcher) -> python.exe -> ffmpeg.exe.
    /// </summary>
    public void KillTree()
    {
        _killed = true;
        try { _process?.Kill(entireProcessTree: true); }
        catch (Exception e) when (e is InvalidOperationException or Win32Exception or NotSupportedException or ObjectDisposedException) { }
    }
}

/// <summary>Runs commands with the data-dir environment and remembers the one in flight, so it can be killed.</summary>
public sealed class CommandRunner
{
    private readonly AppPaths _paths;
    private readonly Dictionary<string, string> _environment;
    private ProcessRunner? _current;

    public CommandRunner(AppPaths paths, IDictionary? inheritedEnvironment = null)
    {
        _paths = paths;
        _environment = paths.ChildEnvironment(inheritedEnvironment ?? System.Environment.GetEnvironmentVariables());
    }

    public IReadOnlyDictionary<string, string> Environment => _environment;

    public int? CurrentProcessId => _current?.ProcessId;

    public async Task<int> RunAsync(ToolCommand command, Action<string> onLine)
    {
        var runner = new ProcessRunner();
        _current = runner;
        try
        {
            Directory.CreateDirectory(_paths.HomeDir);
            return await runner.RunAsync(command, _environment, onLine, _paths.HomeDir);
        }
        finally
        {
            if (ReferenceEquals(_current, runner)) _current = null;
        }
    }

    /// <summary>Runs a command and returns its exit code and the full output (for version checks).</summary>
    public async Task<(int ExitCode, string Output)> CaptureAsync(ToolCommand command)
    {
        var sb = new StringBuilder();
        var code = await RunAsync(command, line => sb.AppendLine(line));
        return (code, sb.ToString());
    }

    public void KillCurrent() => _current?.KillTree();
}
