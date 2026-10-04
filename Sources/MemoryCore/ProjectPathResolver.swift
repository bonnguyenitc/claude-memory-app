import Foundation

/// Maps a `~/.claude/projects/<folder>` name back to the directory it was made for.
///
/// Claude Code names the folder by replacing every non-alphanumeric ASCII
/// character of the working directory with `-`, which can't be reversed on its
/// own. The resolver first reads `cwd` from a session transcript in the folder,
/// then falls back to walking the file system for a path that encodes to the same name.
public final class ProjectPathResolver {
    public struct Resolution: Hashable, Sendable {
        public let path: String
        /// False when the directory is gone: `path` is then the deepest existing
        /// ancestor plus the rest of the folder name, which may be split wrongly.
        public let exists: Bool
    }

    private var cache: [String: Resolution?] = [:]
    private let fileManager = FileManager.default

    public init() {}

    public static func encode(_ path: String) -> String {
        String(path.unicodeScalars.map { scalar in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        })
    }

    public func resolve(projectFolder: URL) -> Resolution? {
        let id = projectFolder.lastPathComponent
        if let cached = cache[id] {
            return cached
        }
        var deepest: String?
        let resolution: Resolution?
        if let cwd = workingDirectoryFromSessions(in: projectFolder, id: id) {
            resolution = Resolution(path: cwd, exists: fileManager.fileExists(atPath: cwd))
        } else if let path = walk(from: "/", toward: id, depth: 0, deepest: &deepest) {
            resolution = Resolution(path: path, exists: true)
        } else if let deepest {
            resolution = Resolution(path: deepest + "/" + id.dropFirst(Self.encode(deepest).count + 1), exists: false)
        } else {
            resolution = nil
        }
        cache[id] = resolution
        return resolution
    }

    private func workingDirectoryFromSessions(in folder: URL, id: String) -> String? {
        let sessions = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "jsonl" } ?? []
        for session in sessions.prefix(5) {
            guard let handle = try? FileHandle(forReadingFrom: session) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 256 * 1024) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let cwd = object["cwd"] as? String else { continue }
                if Self.encode(cwd) == id {
                    return cwd
                }
            }
        }
        return nil
    }

    private func walk(from directory: String, toward id: String, depth: Int, deepest: inout String?) -> String? {
        guard depth < 32, let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { return nil }
        for entry in entries.sorted() {
            let candidate = directory == "/" ? "/" + entry : directory + "/" + entry
            let encoded = Self.encode(candidate)
            guard encoded == id || id.hasPrefix(encoded + "-") else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if encoded == id {
                return candidate
            }
            if candidate.count > deepest?.count ?? 0 {
                deepest = candidate
            }
            if let found = walk(from: candidate, toward: id, depth: depth + 1, deepest: &deepest) {
                return found
            }
        }
        return nil
    }
}
