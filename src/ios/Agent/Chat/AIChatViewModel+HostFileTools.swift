import Foundation

// MARK: - Host (iOS) filesystem tools  [T-host-file-tools]
//
// The existing `file_read` / `file_write` / `file_edit` family operates on the
// iSH Linux fakefs: `resolveHostPath` maps a Linux path through
// `RootfsManager.shared.dataPath` plus `meta.db` metadata. That is the right
// target for shell work, but it cannot reach the app's own sandbox or the real
// device filesystem.
//
// These tools are the iOS-side counterpart. `root` selects the filesystem:
//   "ios" (default) — iOS paths. Absolute means the real path (/var/jb,
//                     /var/mobile, /private/preboot, …). Relative means the
//                     app's Documents directory, so an agent can name a file
//                     without spelling out the container UUID.
//   "ish"           — iSH Linux paths, resolved through the existing
//                     `resolveHostPath` so both families agree.
//
// Read-only by design. Write/command/python/binary slices land separately so a
// failure in one does not take the others down with it.
//
// Every traversal is bounded (entry count, files scanned, per-file bytes) and
// returns through `kMaxToolResultChars`, because an unbounded recursive read is
// how a tool call turns into a multi-second UI stall.

extension AIChatViewModel {

    /// Credential stores refused by every host tool.
    ///
    /// This is not a permission boundary — the app can physically read these —
    /// it is a context boundary: anything returned here is copied into the
    /// model's context and the conversation log. Keychain databases are
    /// therefore refused rather than merely discouraged.
    nonisolated static let hostDeniedPathPrefixes: [String] = [
        "/var/Keychains",
        "/private/var/Keychains",
        "/var/mobile/Library/Keychains",
        "/private/var/mobile/Library/Keychains",
    ]

    /// Result of mapping a caller-supplied path onto a concrete filesystem
    /// location. `error` is user-facing text, never a thrown error, so the
    /// dispatcher can report it through the normal tool-result channel.
    ///
    /// `url` is symlink-RESOLVED and is what the tools actually open.
    /// `displayPath` keeps what the caller asked for, because the two diverge:
    /// `/var/jb/usr/sbin` resolves to `/private/preboot/<uuid>/xina-…/usr/sbin`,
    /// and iSH paths under `/var/minis/**` are symlinks into a shared AppGroup
    /// container. [T-host-symlink-follow] Both roots must follow links: iSH
    /// stores `/var/minis/skills` as a symlink, and opening it without
    /// resolution failed with "could not open file skills" even though the
    /// target was readable.
    struct HostPathResolution {
        let url: URL?
        let displayPath: String
        let error: String?

        init(url: URL?, displayPath: String = "", error: String?) {
            self.url = url
            self.displayPath = displayPath
            self.error = error
        }
    }

    /// Refusal text for a credential store, or nil when the path is allowed.
    nonisolated static func hostDeniedPathError(for path: String) -> String? {
        for denied in AIChatViewModel.hostDeniedPathPrefixes
        where path == denied || path.hasPrefix(denied + "/") {
            // Direction-neutral wording: this helper guards reads AND writes,
            // and the write path used to report "never read keychain
            // material", which described the wrong operation entirely.
            return "Refused: \(path) is a credential store. Host tools never read or write keychain material."
        }
        return nil
    }

    /// Resolve `raw` under the requested root. Relative iOS paths anchor at the
    /// app's Documents directory, which keeps the tool usable without exposing
    /// the container UUID in a prompt.
    func resolveHostToolPath(_ raw: String, root: String) -> HostPathResolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return HostPathResolution(url: nil, error: "Empty path.")
        }
        let candidate: URL
        switch root.lowercased() {
        case "ish":
            guard let url = resolveHostPath(trimmed) else {
                return HostPathResolution(url: nil, error: "Invalid iSH path: \(trimmed)")
            }
            candidate = url

        case "ios", "":
            if trimmed.hasPrefix("/") {
                candidate = URL(fileURLWithPath: trimmed)
            } else {
                let docs = ContainerLocator.documentsDirectory
                candidate = docs.appendingPathComponent(trimmed)
            }

        default:
            return HostPathResolution(url: nil, error: "Unknown root '\(root)'. Use 'ios' or 'ish'.")
        }

        let standardized = candidate.standardizedFileURL
        // Check the literal path AND the resolved one: a symlink under an
        // allowed directory must not become a way into a credential store.
        if let denied = Self.hostDeniedPathError(for: standardized.path) {
            return HostPathResolution(url: nil, error: denied)
        }
        let resolved = standardized.resolvingSymlinksInPath()
        if let denied = Self.hostDeniedPathError(for: resolved.path) {
            return HostPathResolution(url: nil, error: denied)
        }
        return HostPathResolution(url: resolved, displayPath: standardized.path, error: nil)
    }

    // MARK: - Argument helpers

    nonisolated static func hostArgs(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    nonisolated static func hostInt(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    nonisolated static func hostBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    /// Human-readable byte count. Kept deliberately crude — the model only
    /// needs magnitude, and a formatter instance per entry would dominate the
    /// cost of listing a large directory.
    nonisolated static func hostByteSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
    }

    /// Clamp a tool result to the shared character budget, announcing the cut so
    /// the model knows it is looking at a prefix rather than the whole answer.
    nonisolated static func hostClamp(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        return String(head) + "\n\n[truncated: result exceeded \(limit) characters]"
    }

    // MARK: - host_list_files

    func executeHostListFiles(from json: String) async -> FileToolResult {
        guard let dict = Self.hostArgs(json) else {
            return FileToolResult(output: "Error: arguments were not a JSON object.", success: false)
        }
        guard let rawPath = dict["path"] as? String else {
            return FileToolResult(output: "Error: Missing required 'path' parameter.", success: false)
        }
        let root = (dict["root"] as? String) ?? "ios"
        let resolution = resolveHostToolPath(rawPath, root: root)
        if let error = resolution.error {
            return FileToolResult(output: "Error: \(error)", success: false)
        }
        guard let url = resolution.url else {
            return FileToolResult(output: "Error: Unresolved path: \(rawPath)", success: false)
        }
        let limit = max(1, min(Self.hostInt(dict["limit"]) ?? 200, 500))
        let recursive = Self.hostBool(dict["recursive"]) ?? false
        let includeHidden = Self.hostBool(dict["include_hidden"]) ?? false
        let rootLabel = root.lowercased() == "ish" ? "ish" : "ios"

        let result: (String, Bool) = await Task.detached(priority: .userInitiated) { () -> (String, Bool) in
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return ("Error: No such file or directory: \(url.path)", false)
            }
            guard isDirectory.boolValue else {
                return ("Error: Not a directory: \(url.path) (use host_file_info for a file)", false)
            }
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
            let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]

            var lines: [String] = []
            var directories = 0
            var files = 0
            var truncated = false

            func describe(_ child: URL) {
                let values = try? child.resourceValues(forKeys: Set(keys))
                // A symlink reports isDirectory=false for the link itself, so
                // without this branch a linked directory looked like a 0-byte
                // file. Name the target instead of inventing a size.
                if values?.isSymbolicLink == true {
                    let destination = (try? fm.destinationOfSymbolicLink(atPath: child.path)) ?? "?"
                    lines.append("l  \(child.lastPathComponent) -> \(destination)")
                    return
                }
                let isDir = values?.isDirectory ?? false
                if isDir {
                    directories += 1
                    lines.append("d  \(child.lastPathComponent)/")
                } else {
                    files += 1
                    lines.append("f  \(child.lastPathComponent)  \(Self.hostByteSize(values?.fileSize ?? 0))")
                }
            }

            if recursive {
                guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: options, errorHandler: nil) else {
                    return ("Error: Cannot enumerate \(url.path)", false)
                }
                for case let child as URL in enumerator {
                    if lines.count >= limit { truncated = true; break }
                    describe(child)
                }
            } else {
                var children: [URL]?
                var listError: Error?
                do {
                    children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: options)
                } catch {
                    listError = error
                }
                // iSH paths can be enumerable while contentsOfDirectory refuses
                // them (bind-mount overlay). Try a shallow enumerator before
                // reporting failure — and never invent a cause: the previous
                // message said "permission denied" for every error, which hid
                // whatever the real reason was.
                if children == nil {
                    var shallow = options
                    shallow.insert(.skipsSubdirectoryDescendants)
                    if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: shallow, errorHandler: nil) {
                        var collected: [URL] = []
                        for case let child as URL in enumerator { collected.append(child) }
                        if !collected.isEmpty { children = collected }
                    }
                }
                guard let readChildren = children else {
                    let reason = listError?.localizedDescription ?? "unknown error"
                    return ("Error: Cannot read directory \(url.path): \(reason)", false)
                }
                for child in readChildren.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    if lines.count >= limit { truncated = true; break }
                    describe(child)
                }
            }

            var header = "\(url.path) (root=\(rootLabel), \(directories) dir, \(files) file"
            header += truncated ? ", listing truncated at \(limit))" : ")"
            if resolution.displayPath != url.path {
                header += "\nrequested: \(resolution.displayPath) (symlink-resolved)"
            }
            if lines.isEmpty { return (header + "\n(empty directory)", true) }
            var output = ([header] + lines).joined(separator: "\n")
            if truncated {
                output += "\n[truncated: stopped at \(limit) entries; narrow the path or raise 'limit']"
            }
            return (output, true)
        }.value
        return FileToolResult(output: Self.hostClamp(result.0, limit: Self.kMaxToolResultChars), success: result.1)
    }

    // MARK: - host_read_file

    func executeHostReadFile(from json: String) async -> FileToolResult {
        guard let dict = Self.hostArgs(json) else {
            return FileToolResult(output: "Error: arguments were not a JSON object.", success: false)
        }
        guard let rawPath = dict["path"] as? String else {
            return FileToolResult(output: "Error: Missing required 'path' parameter.", success: false)
        }
        let root = (dict["root"] as? String) ?? "ios"
        let resolution = resolveHostToolPath(rawPath, root: root)
        if let error = resolution.error {
            return FileToolResult(output: "Error: \(error)", success: false)
        }
        guard let url = resolution.url else {
            return FileToolResult(output: "Error: Unresolved path: \(rawPath)", success: false)
        }
        let offset = max(1, Self.hostInt(dict["offset"]) ?? 1)
        let lineLimit = Self.hostInt(dict["lines"])
        let charLimit = min(Self.hostInt(dict["max_length"]) ?? Self.kMaxToolResultChars, 80_000)
        let direction = ((dict["direction"] as? String) ?? "head").lowercased()

        let result: (String, Bool) = await Task.detached(priority: .userInitiated) { () -> (String, Bool) in
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return ("Error: No such file: \(url.path)", false)
            }
            guard !isDirectory.boolValue else {
                return ("Error: \(url.path) is a directory (use host_list_files).", false)
            }
            let data: Data
            do {
                data = try Data(contentsOf: url, options: .mappedIfSafe)
            } catch {
                return ("Error reading \(url.path): \(error.localizedDescription)", false)
            }
            let sample = data.prefix(min(data.count, 512))
            if sample.contains(0) {
                let preview = data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
                return ("[\(url.path) | \(data.count) bytes | binary file]\nHex preview: \(preview)", true)
            }
            guard var text = String(data: data, encoding: .utf8) else {
                return ("Error: \(url.path) is \(data.count) bytes but not valid UTF-8. Use the iSH shell for other encodings.", false)
            }
            var lines = text.components(separatedBy: "\n")
            let totalLines = lines.count
            if direction == "tail" {
                let keep = lineLimit ?? lines.count
                if keep < lines.count { lines = Array(lines.suffix(keep)) }
            } else {
                let startIndex = min(offset - 1, max(0, lines.count))
                let endIndex = lineLimit.map { min(startIndex + $0, lines.count) } ?? lines.count
                lines = Array(lines[startIndex..<endIndex])
            }
            text = lines.joined(separator: "\n")
            var header = "\(url.path) (root=\(root.lowercased() == "ish" ? "ish" : "ios"), \(data.count) bytes, \(totalLines) lines)"
            if let lineLimit { header += " [showing \(lines.count) lines]" }
            if text.count > charLimit {
                text = String(text.prefix(charLimit)) + "\n…[truncated at \(charLimit) characters]"
            }
            return ("\(header)\n\n\(text)", true)
        }.value
        return FileToolResult(output: Self.hostClamp(result.0, limit: Self.kMaxToolResultChars), success: result.1)
    }

    // MARK: - host_search_files

    func executeHostSearchFiles(from json: String) async -> FileToolResult {
        guard let dict = Self.hostArgs(json) else {
            return FileToolResult(output: "Error: arguments were not a JSON object.", success: false)
        }
        guard let query = dict["query"] as? String, !query.isEmpty else {
            return FileToolResult(output: "Error: Missing required 'query' parameter.", success: false)
        }
        let root = (dict["root"] as? String) ?? "ios"
        let rawPath = (dict["path"] as? String) ?? (root.lowercased() == "ish" ? "/" : ".")
        let resolution = resolveHostToolPath(rawPath, root: root)
        if let error = resolution.error {
            return FileToolResult(output: "Error: \(error)", success: false)
        }
        guard let url = resolution.url else {
            return FileToolResult(output: "Error: Unresolved path: \(rawPath)", success: false)
        }
        let limit = max(1, min(Self.hostInt(dict["limit"]) ?? 100, 300))
        let maxScanned = max(limit, min(Self.hostInt(dict["max_scanned"]) ?? 20_000, 100_000))
        let includeHidden = Self.hostBool(dict["include_hidden"]) ?? false
        let needle = query.lowercased()

        let result: (String, Bool) = await Task.detached(priority: .userInitiated) { () -> (String, Bool) in
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return ("Error: No such directory: \(url.path)", false)
            }
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: includeHidden ? [] : [.skipsHiddenFiles],
                errorHandler: nil
            ) else {
                return ("Error: Cannot enumerate \(url.path)", false)
            }
            var matches: [String] = []
            var scanned = 0
            var stoppedEarly = false
            for case let child as URL in enumerator {
                scanned += 1
                if scanned > maxScanned { stoppedEarly = true; break }
                if matches.count >= limit { stoppedEarly = true; break }
                if child.lastPathComponent.lowercased().contains(needle) {
                    matches.append(child.path)
                }
            }
            var header = "\(url.path) (root=\(root.lowercased() == "ish" ? "ish" : "ios")) — \(matches.count) match(es) for \"\(query)\", scanned \(min(scanned, maxScanned)) entries"
            if stoppedEarly {
                header += " [stopped early: raise 'limit' or 'max_scanned', or narrow 'path']"
            }
            if matches.isEmpty { return (header + "\n(no matching file names)", true) }
            return (([header] + matches).joined(separator: "\n"), true)
        }.value
        return FileToolResult(output: Self.hostClamp(result.0, limit: Self.kMaxToolResultChars), success: result.1)
    }

    // MARK: - host_search_text

    func executeHostSearchText(from json: String) async -> FileToolResult {
        guard let dict = Self.hostArgs(json) else {
            return FileToolResult(output: "Error: arguments were not a JSON object.", success: false)
        }
        guard let query = dict["query"] as? String, !query.isEmpty else {
            return FileToolResult(output: "Error: Missing required 'query' parameter.", success: false)
        }
        let root = (dict["root"] as? String) ?? "ios"
        let rawPath = (dict["path"] as? String) ?? (root.lowercased() == "ish" ? "/" : ".")
        let resolution = resolveHostToolPath(rawPath, root: root)
        if let error = resolution.error {
            return FileToolResult(output: "Error: \(error)", success: false)
        }
        guard let url = resolution.url else {
            return FileToolResult(output: "Error: Unresolved path: \(rawPath)", success: false)
        }
        let limit = max(1, min(Self.hostInt(dict["limit"]) ?? 100, 300))
        let maxFiles = max(1, min(Self.hostInt(dict["max_files"]) ?? 2_000, 20_000))
        let perFileMatches = max(1, min(Self.hostInt(dict["per_file"]) ?? 5, 50))
        let includeHidden = Self.hostBool(dict["include_hidden"]) ?? false
        let caseSensitive = Self.hostBool(dict["case_sensitive"]) ?? false
        let skipBinary = Self.hostBool(dict["skip_binary"]) ?? true
        let maxFileBytes = 2 * 1024 * 1024
        let needle = caseSensitive ? query : query.lowercased()

        let result: (String, Bool) = await Task.detached(priority: .userInitiated) { () -> (String, Bool) in
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return ("Error: No such path: \(url.path)", false)
            }
            var files: [URL] = []
            if isDirectory.boolValue {
                guard let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: includeHidden ? [] : [.skipsHiddenFiles],
                    errorHandler: nil
                ) else {
                    return ("Error: Cannot enumerate \(url.path)", false)
                }
                for case let child as URL in enumerator {
                    if files.count >= maxFiles { break }
                    let values = try? child.resourceValues(forKeys: [.isRegularFileKey])
                    if values?.isRegularFile == true { files.append(child) }
                }
            } else {
                files = [url]
            }

            var matches: [String] = []
            var scannedFiles = 0
            var skippedLarge = 0
            var skippedBinary = 0
            var truncated = false

            outer: for file in files {
                if matches.count >= limit { truncated = true; break }
                scannedFiles += 1
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if size > maxFileBytes { skippedLarge += 1; continue }
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
                if skipBinary, data.prefix(min(data.count, 512)).contains(0) {
                    skippedBinary += 1
                    continue
                }
                guard let text = String(data: data, encoding: .utf8) else { continue }
                let lines = text.components(separatedBy: "\n")
                var hitsForFile = 0
                for (index, line) in lines.enumerated() {
                    let haystack = caseSensitive ? line : line.lowercased()
                    guard haystack.contains(needle) else { continue }
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    matches.append("\(file.path):\(index + 1): \(String(trimmed.prefix(200)))")
                    hitsForFile += 1
                    if matches.count >= limit { truncated = true; break outer }
                    if hitsForFile >= perFileMatches { break }
                }
            }

            var header = "\(url.path) (root=\(root.lowercased() == "ish" ? "ish" : "ios")) — \(matches.count) match(es) for \"\(query)\" in \(scannedFiles) file(s)"
            if skippedLarge > 0 { header += ", skipped \(skippedLarge) file(s) over \(maxFileBytes) bytes" }
            if skippedBinary > 0 { header += ", skipped \(skippedBinary) binary file(s)" }
            if truncated { header += " [truncated: raise 'limit' or narrow 'path']" }
            if matches.isEmpty { return (header + "\n(no matching lines)", true) }
            return (([header] + matches).joined(separator: "\n"), true)
        }.value
        return FileToolResult(output: Self.hostClamp(result.0, limit: Self.kMaxToolResultChars), success: result.1)
    }

    // MARK: - host_file_info

    func executeHostFileInfo(from json: String) async -> FileToolResult {
        guard let dict = Self.hostArgs(json) else {
            return FileToolResult(output: "Error: arguments were not a JSON object.", success: false)
        }
        guard let rawPath = dict["path"] as? String else {
            return FileToolResult(output: "Error: Missing required 'path' parameter.", success: false)
        }
        let root = (dict["root"] as? String) ?? "ios"
        let resolution = resolveHostToolPath(rawPath, root: root)
        if let error = resolution.error {
            return FileToolResult(output: "Error: \(error)", success: false)
        }
        guard let url = resolution.url else {
            return FileToolResult(output: "Error: Unresolved path: \(rawPath)", success: false)
        }

        let result: (String, Bool) = await Task.detached(priority: .userInitiated) { () -> (String, Bool) in
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return ("\(url.path)\nexists: false", true)
            }
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .fileSizeKey, .creationDateKey,
                .contentModificationDateKey, .isSymbolicLinkKey, .isReadableKey,
            ]
            let values = try? url.resourceValues(forKeys: keys)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            var lines: [String] = [url.path]
            lines.append("root: \(root.lowercased() == "ish" ? "ish" : "ios")")
            lines.append("exists: true")
            // Report the link itself, then the target's real type. `url` is
            // already resolved, so asking IT about symlinks would always say no.
            let requested = URL(fileURLWithPath: resolution.displayPath)
            if let requestedValues = try? requested.resourceValues(forKeys: [.isSymbolicLinkKey]),
               requestedValues.isSymbolicLink == true {
                let destination = (try? fm.destinationOfSymbolicLink(atPath: requested.path)) ?? "?"
                lines.append("symlink: \(resolution.displayPath) -> \(destination)")
                lines.append("resolved: \(url.path)")
            }
            lines.append("type: \((values?.isDirectory ?? isDirectory.boolValue) ? "directory" : "file")")
            lines.append("readable: \(values?.isReadable == true ? "yes" : "no")")
            if let size = values?.fileSize, values?.isDirectory != true {
                lines.append("size: \(size) bytes (\(Self.hostByteSize(size)))")
            }
            if let created = values?.creationDate {
                lines.append("created: \(formatter.string(from: created))")
            }
            if let modified = values?.contentModificationDate {
                lines.append("modified: \(formatter.string(from: modified))")
            }
            return (lines.joined(separator: "\n"), true)
        }.value
        return FileToolResult(output: Self.hostClamp(result.0, limit: Self.kMaxToolResultChars), success: result.1)
    }
}
