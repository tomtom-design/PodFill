import Foundation

/// A Spotify link the app knows how to hand to spotdl.
public struct SpotifyLink: Equatable, Sendable {
    public enum Kind: String, Sendable { case track, album, playlist }
    public let kind: Kind
    public let id: String
    /// Canonical URL without tracking parameters (`?si=...`) or locale prefixes (`/intl-fr/`).
    public var url: String { "https://open.spotify.com/\(kind.rawValue)/\(id)" }
    public var isList: Bool { kind != .track }
}

public enum SpotifyURL {
    /// Splits pasted text into links. Returns the valid links and the lines that were not understood.
    public static func parse(_ text: String) -> (links: [SpotifyLink], rejected: [String]) {
        var links: [SpotifyLink] = []
        var rejected: [String] = []
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        for token in text.components(separatedBy: separators) where !token.isEmpty {
            if let link = link(from: token) {
                if !links.contains(link) { links.append(link) }
            } else {
                rejected.append(token)
            }
        }
        return (links, rejected)
    }

    static func link(from token: String) -> SpotifyLink? {
        // Also accept spotify:track:ID URIs.
        if token.hasPrefix("spotify:") {
            let parts = token.split(separator: ":").map(String.init)
            if parts.count == 3, let kind = SpotifyLink.Kind(rawValue: parts[1]), isID(parts[2]) {
                return SpotifyLink(kind: kind, id: parts[2])
            }
            return nil
        }
        guard let comps = URLComponents(string: token),
              let host = comps.host, host == "open.spotify.com" || host == "spotify.com" || host == "play.spotify.com"
        else { return nil }
        var path = comps.path.split(separator: "/").map(String.init)
        if let first = path.first, first.hasPrefix("intl-") { path.removeFirst() }
        guard path.count >= 2, let kind = SpotifyLink.Kind(rawValue: path[0]), isID(path[1]) else { return nil }
        return SpotifyLink(kind: kind, id: path[1])
    }

    private static func isID(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
