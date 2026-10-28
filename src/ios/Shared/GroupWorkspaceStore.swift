import Foundation

/// Stable, group-scoped workspace storage. The visible directory begins with
/// the group name and ends with a hex-encoded immutable group id, so duplicate
/// names and renames never merge unrelated files.
enum GroupWorkspaceStore {
    private static let lock = NSLock()

    private static var root: URL {
        AIChatViewModel.minisConfigRoot.appendingPathComponent("group-workspaces", isDirectory: true)
    }

    private static func key(_ folderID: String) -> String {
        folderID.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private static func safeName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        let scalars = name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map {
            invalid.contains($0) ? "_" : String($0)
        }.joined()
        let collapsed = scalars.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String((collapsed.isEmpty ? "未命名分组" : collapsed).prefix(48))
    }

    static func directoryName(folderID: String, name: String) -> String {
        safeName(name) + "--" + key(folderID)
    }

    private static func existingDirectory(folderID: String) -> URL? {
        let suffix = "--" + key(folderID)
        return (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?
            .first { $0.lastPathComponent.hasSuffix(suffix) }
    }

    @discardableResult
    static func ensure(folderID: String, name: String? = nil) -> URL {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let current = existingDirectory(folderID: folderID)
        guard let name else {
            if let current { return current }
            let fallback = root.appendingPathComponent("分组--" + key(folderID), isDirectory: true)
            try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
            return fallback
        }
        let desired = root.appendingPathComponent(directoryName(folderID: folderID, name: name), isDirectory: true)
        if let current, current.standardizedFileURL != desired.standardizedFileURL,
           !fm.fileExists(atPath: desired.path) {
            do { try fm.moveItem(at: current, to: desired); return desired }
            catch { return current }
        }
        if let current { return current }
        try? fm.createDirectory(at: desired, withIntermediateDirectories: true)
        return desired
    }

    static func adoptSessionWorkspace(sessionID: String, into destination: URL) {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let source = AIChatViewModel.minisWorkspacePersistentDir(for: sessionID)
        guard source.standardizedFileURL != destination.standardizedFileURL,
              fm.fileExists(atPath: source.path),
              let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil),
              !items.isEmpty else { return }
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in items {
            var target = destination.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                target = destination.appendingPathComponent(item.deletingPathExtension().lastPathComponent
                    + "-会话-" + String(sessionID.prefix(8))
                    + (item.pathExtension.isEmpty ? "" : "." + item.pathExtension))
                if fm.fileExists(atPath: target.path) {
                    target = destination.appendingPathComponent(item.deletingPathExtension().lastPathComponent
                        + "-会话-" + String(sessionID.prefix(8)) + "-" + String(UUID().uuidString.prefix(6))
                        + (item.pathExtension.isEmpty ? "" : "." + item.pathExtension))
                }
            }
            try? fm.moveItem(at: item, to: target)
        }
        if ((try? fm.contentsOfDirectory(atPath: source.path)) ?? []).isEmpty {
            try? fm.removeItem(at: source)
        }
    }

    static func merge(source: ChatFolder, into target: ChatFolder) throws {
        let destination = ensure(folderID: target.id, name: target.name)
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard let sourceDirectory = existingDirectory(folderID: source.id),
              sourceDirectory.standardizedFileURL != destination.standardizedFileURL else { return }
        let items = try fm.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
        for item in items {
            var targetURL = destination.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: targetURL.path) {
                targetURL = destination.appendingPathComponent(item.deletingPathExtension().lastPathComponent
                    + "-来自-" + safeName(source.name) + "-" + String(UUID().uuidString.prefix(6))
                    + (item.pathExtension.isEmpty ? "" : "." + item.pathExtension))
            }
            try fm.moveItem(at: item, to: targetURL)
        }
        try fm.removeItem(at: sourceDirectory)
    }

    static func remove(folder: ChatFolder, preserve: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard let source = existingDirectory(folderID: folder.id), fm.fileExists(atPath: source.path) else { return }
        if !preserve {
            try fm.removeItem(at: source)
            return
        }
        let preservedRoot = AIChatViewModel.minisSharedPersistentDir
            .appendingPathComponent("保留的分组工作区", isDirectory: true)
        try fm.createDirectory(at: preservedRoot, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var destination = preservedRoot.appendingPathComponent(safeName(folder.name) + "-" + stamp, isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            destination = preservedRoot.appendingPathComponent(destination.lastPathComponent + "-" + String(UUID().uuidString.prefix(8)), isDirectory: true)
        }
        try fm.moveItem(at: source, to: destination)
    }
}
