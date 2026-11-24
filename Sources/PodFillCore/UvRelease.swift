import Foundation

public struct UvAsset: Equatable, Sendable {
    public let name: String
    public let sha256: String
    public var url: URL { URL(string: "\(UvRelease.baseURL)/\(name)")! }
    public var checksumURL: URL { URL(string: "\(UvRelease.baseURL)/\(name).sha256")! }
}

/// The pinned uv release (github.com/astral-sh/uv), shared with the Windows app's UvRelease.cs.
/// The self-check fails if the two pins differ, so bump both together: change `version` and copy the new
/// release's .sha256 contents here and into windows/src/PodFill.Core/UvRelease.cs.
public enum UvRelease {
    public static let version = "0.13.9"
    public static let baseURL = "https://github.com/astral-sh/uv/releases/download/\(version)"

    public static let sha256: [String: String] = [
        "uv-aarch64-apple-darwin.tar.gz": "5aeca67f2283f75235de40d0bd9c0a5bbc5fce23b6d48b3bf9fa1b2db08382ca",
        "uv-x86_64-apple-darwin.tar.gz": "617a3211261b0fc739562f0071aa34e9739797c510208ede8e2977c30903d041",
    ]

    public enum Arch: String, Sendable { case arm64, x86_64 }

    /// The machine's architecture, not the process's: an Apple Silicon Mac running the Intel slice under Rosetta
    /// still gets the arm64 uv (and so a native Python and ffmpeg).
    public static func machineArch() -> Arch {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1 ? .arm64 : .x86_64
    }

    public static func asset(for arch: Arch) -> UvAsset {
        let name = arch == .arm64 ? "uv-aarch64-apple-darwin.tar.gz" : "uv-x86_64-apple-darwin.tar.gz"
        return UvAsset(name: name, sha256: sha256[name]!)
    }

    /// Reads a uv ".sha256" file: "<64 hex chars>  <file name>".
    public static func parseChecksumFile(_ text: String) throws -> String {
        let token = text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard token.count == 64, token.allSatisfy(\.isHexDigit) else {
            throw SetupError("The published uv checksum file is not in the expected format.")
        }
        return token.lowercased()
    }
}
