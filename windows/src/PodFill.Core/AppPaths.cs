using System.Collections;

namespace PodFill.Core;

/// <summary>
/// Layout of the private data dir. Everything PodFill installs or writes (other than the MP3s) lives here,
/// so uninstalling is "delete this folder and PodFill.exe".
/// <code>
/// %LOCALAPPDATA%\PodFill\
///   uv\uv.exe                  pinned uv release (verified download)
///   tools\spotdl\              the spotdl tool environment (UV_TOOL_DIR)
///   bin\spotdl.exe             its launcher (UV_TOOL_BIN_DIR)
///   python\                    uv-managed Python (UV_PYTHON_INSTALL_DIR)
///   cache\                     uv cache (UV_CACHE_DIR)
///   home\.spotdl\              spotdl's own folder: config.json, ffmpeg.exe, deno.exe, temp, errors
///   deno-cache\                DENO_DIR
///   settings.json              remembered destination
/// </code>
/// spotdl always uses "~/.spotdl" (Path.home() / ".spotdl"). Child processes get HOME (USERPROFILE on Windows)
/// pointed at home\, so spotdl's folder lands inside the data dir and never touches a real ~/.spotdl.
/// </summary>
public sealed class AppPaths
{
    public AppPlatform Platform { get; }

    public AppPaths(AppPlatform platform) => Platform = platform;

    private string In(params string[] parts) => Platform.Join(DataDir, parts);

    public string DataDir => Platform.DataDir;
    public string UvDir => In("uv");
    public string Uv => In("uv", Platform.Executable("uv"));
    public string ToolDir => In("tools");
    public string BinDir => In("bin");
    public string Spotdl => In("bin", Platform.Executable("spotdl"));
    public string PythonDir => In("python");
    public string PythonBinDir => In("python-bin");
    public string CacheDir => In("cache");
    public string HomeDir => In("home");
    public string SpotdlHome => In("home", ".spotdl");
    /// <summary>Where `spotdl --download-ffmpeg` puts ffmpeg (spotdl.utils.ffmpeg.download_ffmpeg); passed back via --ffmpeg.</summary>
    public string Ffmpeg => In("home", ".spotdl", Platform.Executable("ffmpeg"));
    /// <summary>Where `spotdl --download-deno` puts Deno; spotdl hands it to yt-dlp as its JavaScript runtime.</summary>
    public string Deno => In("home", ".spotdl", Platform.Executable("deno"));
    public string SpotdlTemp => In("home", ".spotdl", "temp");
    public string DenoDir => In("deno-cache");
    public string DownloadsDir => In("downloads");
    public string SettingsFile => In("settings.json");

    /// <summary>Inherited variables that would make the private Python/uv behave differently from what we tested.</summary>
    private static readonly string[] RemovedVariables =
    [
        "VIRTUAL_ENV", "CONDA_PREFIX", "CONDA_DEFAULT_ENV", "PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP",
        "PYTHONUSERBASE", "PYTHONSAFEPATH", "FORCE_COLOR", "CLICOLOR_FORCE", "TERM",
    ];

    /// <summary>
    /// The environment for every child process (uv, spotdl and what they spawn): the inherited one (Windows needs
    /// SystemRoot, PATH, TEMP, proxies...), minus Python/uv settings, plus the data-dir isolation and UTF-8 output.
    /// </summary>
    public Dictionary<string, string> ChildEnvironment(IDictionary inherited)
    {
        var env = new Dictionary<string, string>(Platform.EnvironmentComparer);
        foreach (DictionaryEntry e in inherited)
        {
            if (e.Key is string k && e.Value is string v) env[k] = v;
        }
        foreach (var key in env.Keys.ToList())
        {
            if (key.StartsWith("UV_", StringComparison.OrdinalIgnoreCase)
                || RemovedVariables.Contains(key, Platform.EnvironmentComparer))
            {
                env.Remove(key);
            }
        }

        env[Platform.HomeVariable] = HomeDir;
        // Python output: UTF-8 (song names are Unicode), unbuffered, no colors, no line wrapping.
        env["PYTHONIOENCODING"] = "utf-8";
        env["PYTHONUTF8"] = "1";
        env["PYTHONUNBUFFERED"] = "1";
        env["COLUMNS"] = "1000";
        env["NO_COLOR"] = "1";
        // uv: keep tools, Python, cache and shims inside the data dir; only uv-managed Python; ignore user config.
        env["UV_TOOL_DIR"] = ToolDir;
        env["UV_TOOL_BIN_DIR"] = BinDir;
        env["UV_PYTHON_INSTALL_DIR"] = PythonDir;
        env["UV_PYTHON_BIN_DIR"] = PythonBinDir;
        env["UV_PYTHON_INSTALL_BIN"] = "0";
        env["UV_PYTHON_INSTALL_REGISTRY"] = "0";   // no PEP 514 registry entries on Windows
        env["UV_CACHE_DIR"] = CacheDir;
        env["UV_MANAGED_PYTHON"] = "1";            // never pick up a system or Microsoft Store Python
        env["UV_NO_CONFIG"] = "1";
        env["UV_NO_PROGRESS"] = "1";
        // Deno (yt-dlp's JavaScript runtime): its cache in the data dir, no update checks.
        env["DENO_DIR"] = DenoDir;
        env["DENO_NO_UPDATE_CHECK"] = "1";
        return env;
    }
}

/// <summary>The exact command lines PodFill runs. Same spotdl arguments as the Mac app.</summary>
public static class Commands
{
    /// <summary>spotdl 4.6 needs Python &gt;=3.11,&lt;3.16; 3.13 has prebuilt wheels for every dependency on Windows x64 and arm64.</summary>
    public const string PythonVersion = "3.13";

    /// <summary>The output parser was verified against spotdl 4.6.0; stay on 4.x so an upgrade can't change the format under it.</summary>
    public const string SpotdlRequirement = "spotdl>=4.6,<5";

    public static ToolCommand InstallSpotdl(AppPaths p) =>
        new(p.Uv, ["tool", "install", SpotdlRequirement, "--python", PythonVersion]);

    /// <summary>Re-resolves the whole tool environment, so yt-dlp (and yt-dlp-ejs) move to their latest release too.</summary>
    public static ToolCommand UpgradeSpotdl(AppPaths p) => new(p.Uv, ["tool", "upgrade", "spotdl"]);

    // Both prompt "already installed, overwrite? (y/N)" when an ffmpeg/deno is on PATH; answer yes so the
    // private copy is always written (stdin is otherwise closed, which would crash input()).
    public static ToolCommand DownloadFfmpeg(AppPaths p) => new(p.Spotdl, ["--download-ffmpeg"], "y\n");
    public static ToolCommand DownloadDeno(AppPaths p) => new(p.Spotdl, ["--download-deno"], "y\n");

    public static ToolCommand UvVersion(AppPaths p) => new(p.Uv, ["--version"]);
    public static ToolCommand SpotdlVersion(AppPaths p) => new(p.Spotdl, ["--version"]);
    public static ToolCommand FfmpegVersion(AppPaths p) => new(p.Ffmpeg, ["-version"]);

    public static ToolCommand Download(AppPaths p, SpotdlJob job, string destination) =>
        new(p.Spotdl, job.Arguments(p.Ffmpeg, destination, p.Platform.Separator));
}
