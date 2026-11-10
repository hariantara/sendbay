import Foundation

public enum PhotoImport {
    public static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "dng", "raw",
        "mp4", "mov", "3gp", "mkv", "webm",
    ]

    public struct Item: Equatable, Sendable {
        public var object: ObjectInfo
        public var destination: URL
    }

    /// Walks DCIM on every storage and returns all photos/videos found.
    /// Hidden folders (e.g. `.thumbnails`) are skipped.
    public static func findMedia(in session: MTPSession, storages: [UInt32]) throws -> [ObjectInfo] {
        var found: [ObjectInfo] = []
        for storage in storages {
            let root = try session.list(storage: storage)
            guard let dcim = root.first(where: { $0.isFolder && $0.name.caseInsensitiveCompare("DCIM") == .orderedSame }) else {
                continue
            }
            var queue = [dcim.handle]
            while let folder = queue.popLast() {
                for object in try session.list(storage: storage, parent: folder) where !object.isHidden {
                    if object.isFolder {
                        queue.append(object.handle)
                    } else if isMedia(object.name) {
                        found.append(object)
                    }
                }
            }
        }
        return found
    }

    public static func isMedia(_ name: String) -> Bool {
        mediaExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Decides what to copy. A file already in `folder` with the same name and
    /// size counts as imported. A same-named file with a different size gets a
    /// numbered name instead of being overwritten.
    public static func plan(_ media: [ObjectInfo], into folder: URL, fileManager: FileManager = .default) -> [Item] {
        var taken = Set<String>()
        var items: [Item] = []
        for object in media.sorted(by: { $0.name < $1.name }) {
            let target = folder.appendingPathComponent(object.name)
            if let size = fileSize(target, fileManager), size == object.size { continue }
            var candidate = target
            var n = 1
            while fileManager.fileExists(atPath: candidate.path) || taken.contains(candidate.lastPathComponent) {
                candidate = numbered(target, n)
                if let size = fileSize(candidate, fileManager), size == object.size { break }
                n += 1
            }
            if let size = fileSize(candidate, fileManager), size == object.size { continue }
            taken.insert(candidate.lastPathComponent)
            items.append(Item(object: object, destination: candidate))
        }
        return items
    }

    static func numbered(_ url: URL, _ n: Int) -> URL {
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    private static func fileSize(_ url: URL, _ fm: FileManager) -> UInt64? {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }
}
