using System.Diagnostics;
using System.Runtime.InteropServices;

namespace PodFill.Core;

public enum OSKind { Windows, MacOS, Linux }

/// <summary>
/// Every difference between Windows (the target) and macOS (where it is developed and tested) lives here:
/// paths and separators, executable suffixes, the uv download asset, and how to reveal files.
/// Constructed explicitly in tests, so the Windows rules are checked on any machine.
/// </summary>
public sealed class AppPlatform
{
    /// <summary>Overrides the data dir. Test runs and the CI smoke test set it so they never touch real locations.</summary>
    public const string DataDirVariable = "PODFILL_DATA_DIR";

    public OSKind OS { get; }
    /// <summary>The machine's architecture (not the process's): picks the uv build.</summary>
    public Architecture Architecture { get; }
    public string UserProfile { get; }
    /// <summary>%LOCALAPPDATA%\PodFill on Windows, ~/Library/Application Support/PodFill on macOS, or the override.</summary>
    public string DataDir { get; }

    public AppPlatform(OSKind os, Architecture architecture, string userProfile, string localAppData, string? dataDirOverride)
    {
        OS = os;
        Architecture = architecture;
        UserProfile = userProfile;
        DataDir = string.IsNullOrWhiteSpace(dataDirOverride) ? Join(localAppData, "PodFill") : dataDirOverride;
    }

    public static AppPlatform Current { get; } = Detect();

    private static AppPlatform Detect()
    {
        var os = OperatingSystem.IsWindows() ? OSKind.Windows : OperatingSystem.IsMacOS() ? OSKind.MacOS : OSKind.Linux;
        var dataOverride = Environment.GetEnvironmentVariable(DataDirVariable);
        return new AppPlatform(
            os,
            RuntimeInformation.OSArchitecture,
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            // Windows: %LOCALAPPDATA%. macOS (.NET 8+): ~/Library/Application Support.
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.DoNotVerify),
            string.IsNullOrWhiteSpace(dataOverride) ? null : Path.GetFullPath(dataOverride));
    }

    public bool IsWindows => OS == OSKind.Windows;
    public char Separator => IsWindows ? '\\' : '/';
    public string ExeSuffix => IsWindows ? ".exe" : "";
    public string Executable(string name) => name + ExeSuffix;

    /// <summary>Python's os.path.expanduser / Path.home() read USERPROFILE on Windows and HOME elsewhere.</summary>
    public string HomeVariable => IsWindows ? "USERPROFILE" : "HOME";

    /// <summary>Windows environment variable names are case-insensitive.</summary>
    public StringComparer EnvironmentComparer => IsWindows ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    /// <summary>%USERPROFILE%\Music\iPod (~/Music/iPod on macOS).</summary>
    public string DefaultDestination => Join(UserProfile, "Music", "iPod");

    public string FileManagerName => OS switch
    {
        OSKind.Windows => "Explorer",
        OSKind.MacOS => "Finder",
        _ => "file manager",
    };

    public UvAsset UvAsset => UvRelease.AssetFor(OS, Architecture);

    /// <summary>Path join with this platform's separator (not the host's), so Windows paths can be built and tested anywhere.</summary>
    public string Join(string first, params string[] rest)
    {
        var result = first.Length > 1 ? first.TrimEnd('/', '\\') : first;
        foreach (var part in rest)
        {
            if (result.Length > 0 && result[^1] != Separator) result += Separator;
            result += part.Trim('/', '\\');
        }
        return result;
    }

    /// <summary>Opens the file manager with <paramref name="file"/> selected, or just the folder.</summary>
    public ProcessStartInfo RevealCommand(string? file, string folder)
    {
        if (IsWindows)
        {
            // explorer.exe parses its own command line: "/select,<path>" must stay one quoted argument string.
            var psi = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
            psi.Arguments = file is null ? $"\"{folder}\"" : $"/select,\"{file}\"";
            return psi;
        }
        var open = new ProcessStartInfo(OS == OSKind.MacOS ? "open" : "xdg-open") { UseShellExecute = false };
        if (file is not null && OS == OSKind.MacOS) open.ArgumentList.Add("-R");
        open.ArgumentList.Add(file is not null && OS == OSKind.MacOS ? file : folder);
        return open;
    }
}
