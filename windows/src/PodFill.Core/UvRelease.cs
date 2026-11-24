using System.Runtime.InteropServices;

namespace PodFill.Core;

public sealed record UvAsset(string Name, string Sha256)
{
    public bool IsZip => Name.EndsWith(".zip", StringComparison.Ordinal);
    public string Url => $"{UvRelease.BaseUrl}/{Name}";
    public string ChecksumUrl => Url + ".sha256";
}

/// <summary>
/// The pinned uv release (github.com/astral-sh/uv). The hashes below were copied from the release's published
/// .sha256 files; setup checks the download against both the published file and this pin.
/// To bump: change Version and replace the four hashes with the new release's .sha256 contents.
/// </summary>
public static class UvRelease
{
    public const string Version = "0.13.9";
    public const string BaseUrl = "https://github.com/astral-sh/uv/releases/download/" + Version;

    private static readonly Dictionary<string, string> Sha256 = new()
    {
        ["uv-x86_64-pc-windows-msvc.zip"] = "edd61f7f5728a56cc62455386661860bdfc7bab65872f39b0c25bdcc1d8e1beb",
        ["uv-aarch64-pc-windows-msvc.zip"] = "72eed595983a4d7d22d79f21065b0f4479cc7e5c7a89104bb410c8f47559a878",
        ["uv-aarch64-apple-darwin.tar.gz"] = "5aeca67f2283f75235de40d0bd9c0a5bbc5fce23b6d48b3bf9fa1b2db08382ca",
        ["uv-x86_64-apple-darwin.tar.gz"] = "617a3211261b0fc739562f0071aa34e9739797c510208ede8e2977c30903d041",
    };

    public static UvAsset AssetFor(OSKind os, Architecture arch)
    {
        var name = (os, arch) switch
        {
            (OSKind.Windows, Architecture.X64) => "uv-x86_64-pc-windows-msvc.zip",
            (OSKind.Windows, Architecture.Arm64) => "uv-aarch64-pc-windows-msvc.zip",
            (OSKind.MacOS, Architecture.Arm64) => "uv-aarch64-apple-darwin.tar.gz",
            (OSKind.MacOS, Architecture.X64) => "uv-x86_64-apple-darwin.tar.gz",
            _ => throw new PlatformNotSupportedException($"PodFill has no uv download for {os} on {arch}."),
        };
        return new UvAsset(name, Sha256[name]);
    }

    /// <summary>Reads a uv ".sha256" file: "&lt;64 hex chars&gt;  &lt;file name&gt;".</summary>
    public static string ParseChecksumFile(string text)
    {
        var token = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
        if (token.Length != 64 || !token.All(Uri.IsHexDigit))
            throw new FormatException("The published uv checksum file is not in the expected format.");
        return token.ToLowerInvariant();
    }
}
