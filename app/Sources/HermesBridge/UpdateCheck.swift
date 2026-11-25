import Foundation

/// Is there a newer stable Hermes than the one in the box? One public GitHub request (the source in hermes.lock.json),
/// at most every 6 hours, with a generic client name; nothing about the user is sent. Vera never updates by itself:
/// a new version goes in only by the procedure (scripts/build-hermes.sh <tag> + bundle, docs/hermes-updates.md).
public enum UpdateCheck {
    /// «https://github.com/Owner/repo.git» → the API URL of its latest release.
    public static func latestReleaseURL(source: String) -> URL? {
        guard let r = source.range(of: "github.com/") else { return nil }
        var path = String(source[r.upperBound...])
        if path.hasSuffix(".git") { path.removeLast(4) }
        return URL(string: "https://api.github.com/repos/\(path)/releases/latest")
    }

    /// The stable tag (vX.Y.Z) from a releases/latest answer, or nil.
    public static func tag(from json: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let tag = obj["tag_name"] as? String, obj["prerelease"] as? Bool != true,
              parse(tag) != nil else { return nil }
        return tag
    }

    public static func parse(_ tag: String) -> [Int]? {
        let t = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = t.split(separator: ".").map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }

    /// true when `latest` is a newer stable version than `current`.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let a = parse(latest), let b = parse(current) else { return false }
        return a.lexicographicallyPrecedes(b) == false && a != b
    }

    public static func fetchLatest(source: String) async -> String? {
        guard let url = latestReleaseURL(source: source) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("vera-update-check", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return tag(from: data)
    }
}
