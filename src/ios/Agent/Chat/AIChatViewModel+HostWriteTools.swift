import Foundation

// MARK: - Host (iOS) filesystem WRITE tools  [T-host-write-tools]
//
// Companion to AIChatViewModel+HostFileTools.swift. Same two roots ("ios" for
// the real device, "ish" for the Linux view), same symlink resolution, same
// path mapping — only the direction of data changes.
//
// Why these are separate tools rather than a `write: true` flag on the read
// family: the read family is safe to call speculatively (the model guesses a
// path and reads it), while a write is a side effect that cannot be undone by
// re-running the call. Different blast radius deserves a different, narrower
// interface — and a smaller description the model cannot misapply.
//
// SAFETY MODEL
//
// On a TrollStore/jailbroken device these tools can physically write to the
// jailbreak bootstrap, and a careless write there breaks the device's ability
// to boot into a usable state. The app is running as `mobile`, so the
// filesystem is the only real boundary and it is not enough. Therefore:
//
//   1. Credential stores are refused unconditionally — even with
//      `allow_system: true`. There is no legitimate reason for an agent to
//      rewrite a keychain database, and unlike a bad tweak edit it is not
//      recoverable from a backup.
//   2. System roots (jailbreak bootstrap, /System, /usr, /bin, /sbin,
//      /Applications, and the rootless /var/jb equivalent) are refused unless
//      the caller passes `allow_system: true`. That flag exists for the
//      legitimate case — a tweak developer replacing a dylib in the bootstrap —
//      but it cannot be set by accident, and the refusal message says what to
//      pass.
//   3. Deletion of a directory requires `recursive: true`. A recursive delete
//      is the single most destructive thing an agent can do here, so it is
//      never the default reading of "delete this path".
//
// The refusal is enforced against BOTH the literal path and the symlink-
// resolved one, so a link inside an allowed directory cannot smuggle a write
// into a denied one.

extension AIChatViewModel {

    /// Paths that always refuse writes, regardless of `allow_system`.
    ///
    /// Kept separate from `hostDeniedPathPrefixes` (which also guards reads)
    /// because the two lists answer different questions: that one protects the
    /// conversation context, this one protects the device.
    nonisolated static let hostWriteForbiddenPathPrefixes: [String] = [
        "/var/Keychains",
        "/private/var/Keychains",
        "/var/mobile/Library/Keychains",
        "/private/var/mobile/Library/Keychains",
        // The dynamic-loader / trust caches. Corrupting these bricks the
        // jailbreak environment rather than merely breaking one tweak.
        "/var/db/launchd.db",
        "/private/var/db/launchd.db",
        "/var/jb/basebin",
    ]

    /// Roots that hold the OS and the jailbreak bootstrap. Writable only when
    /// the caller explicitly opts in with `allow_system: true`.
    nonisolated static let hostWriteSystemPathPrefixes: [String] = [
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/Applications",
        "/private/preboot",
        "/var/jb",          // resolved form is /private/preboot/…, but keep the
                            // literal prefix too: a caller may pass it directly
                            // and resolution can fail on a missing target.
        "/var/Library",
        "/private/var/Library",
        "/cores",
    ]

    /// Write-permission verdict for one resolved path.
    /// Returned instead of a Bool so the refusal text can name the escape hatch.
    nonisolated static func hostWriteDenial(for path: String, allowSystem: Bool) -> String? {
        for forbidden in AIChatViewModel.hostWriteForbiddenPathPrefixes
        where path == forbidden || path.hasPrefix(forbidden + "/") {
            return "Refused: \(path) is protected and can never be written by a tool, even with allow_system."
        }
        guard !allowSystem else { return nil }
        for system in AIChatViewModel.hostWriteSystemPathPrefixes
        where path == system || path.hasPrefix(system + "/") {
            return "Refused: \(path) is inside the system/jailbreak area (\(system)). "
                + "This tool only writes here when the call passes allow_system=true, "
                + "because a bad write to the bootstrap can leave the device unbootable. "
                + "Re-issue with allow_system=true if that is genuinely what you intend."
        }
        return nil
    }

    /// Resolve a path for a write and apply BOTH denial lists.
    func resolveHostWriteTarget(_ raw: String, root: String, allowSystem: Bool) -> HostPathResolution {
        let resolution = resolveHostToolPath(raw, root: root)
        if let error = resolution.error {
            return HostPathResolution(url: nil, error: error)
        }
        guard let url = resolution.url else {
            return HostPathResolution(url: nil, error: "Unresolved path: \(raw)")
        }
        if let denied = Self.hostWriteDenial(for: url.path, allowSystem: allowSystem) {
            return HostPathResolution(url: nil, error: denied)
        }
        return resolution
    }

    /// Shared scaffolding for every write tool: parse args, resolve the path
    /// with the write guard, and return either an error result or the target.
    func hostWriteTarget(
        from dict: [String: Any]
    ) -> (url: URL, root: String, allowSystem: Bool, error: FileToolResult?) {
        let root = (dict["root"] as? String) ?? "ios"
        // The in-app prompt asks for `allow_system`; accept `allowSystem` too so
        // a model that camel-cases the key is not silently refused.
        let allowSystem = Self.hostBool(dict["allow_system"])
            ?? Self.hostBool(dict["allowSystem"])
            ?? false
        guard let rawPath = dict["path"] as? String else {
            return (URL(fileURLWithPath: "/"), root, allowSystem,
                    FileToolResult(output: "Error: Missing required 'path' parameter.", success: false))
        }
        let resolution = resolveHostWriteTarget(rawPath, root: root, allowSystem: allowSystem)
        if let error = resolution.error {
            return (URL(fileURLWithPath: "/"), root, allowSystem,
                    FileToolResult(output: "Error: \(error)", success: false))
        }
        guard let url = resolution.url else {
            return (URL(fileURLWithPath: "/"), root, allowSystem,
                    FileToolResult(output: "Error: Unresolved path: \(rawPath)", success: false))
        }
        return (url, root, allowSystem, nil)
    }

    // MARK: - host_write_file

    func executeHostWriteFile(from json: String) async -> FileToolResult {
        guard let dict = Self.hostArgs(json) else {
            return FileToolResult(output: "Error: arguments were not a JSON object.", success: false)
        }
        let target = hostWriteTarget(from: dict)
        if let error = target.error { return error }
        guard let content = dict["content"] as? String else {
            return FileToolResult(output: "Error: Missing required 'content' parameter.", success: false)
        }
        let createDirs = Self.hostBool(dict["create_dirs"]) ?? true
        let overwrite = Self.hostBool(dict["overwrite"]) ?? true
        let url = target.url
        let rootLabel = target.root.lowercased() == "ish" ? "ish" : "ios"

        let result: (String, Bool) = await Task.detached(priority: .userInitiated) { () -> (String, Bool) in
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if exists && isDirectory.boolValue {
                return ("Error: \(url.path) is a directory, not a file.", false)
            }
            // Never clobber by surprise: an existing file needs overwrite=true,
            // so a mistaken path fails loudly instead of destroying data.
            if exists && !overwrite {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return ("Error: \(url.path) already exists (\(Self.hostByteSize(size))). "
                        + "Pass overwrite=true to replace it, or use host_edit_file to change it in place.", false)
            }
            if createDirs {
                let parent = url.deletingLastPathComponent()
                if !fm.fileExists(atPath: parent.path) {
                    do {
                        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                    } catch {
                        return ("Error: Cannot create parent directory \(parent.path): \(error.localizedDescription)", false)
                    }
                }
            }
            guard let data = content.data(using: .utf8) else {
                return ("Error: Content could not be encoded as UTF-8.", false)
            }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                return ("Error: Cannot write \(url.path): \(error.localizedDescription)", false)
            }
            var lines = ["Wrote \(data.count) bytes (\(Self.hostByteSize(data.count))) to \(url.path)"]
            lines.append("root: \(rootLabel)")
            lines.append(exists ? "replaced existing file" : "created new file")
            return (lines.joined(separator: "\n"), true)
        }.value
        return FileToolResult(output: Self.hostClamp(result.0, limit: Self.kMaxToolResultChars), success: result.1)
    }

    // MARK: - host_append_file

    func executeHostAppendFile(from json: String) async -> FileToolResult {
        guard let dict = Self.hostArgs(json) else {
            return FileToolResult(output: "Error: arguments were not a JSON object.", success: false)
        }
        let target = hostWriteTarget(from: dict)
        if let error = target.error { return error }
        guard let content = dict["content"] as? String else {
            return FileToolResult(output: "Error: Missing required 'content' parameter.", success: false)
        }
        let createDirs = Self.hostBool(dict["create_dirs"]) ?? true
        let url = target.url

        let result: (String, Bool) = await Task.detached(priority: .userInitiated) { () -> (String, Bool) in
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue {
                return ("Error: \(url.path) is a directory, not a file.", false)
            }
            if createDirs {
                let parent = url.deletingLastPathComponent()
                if !fm.fileExists(atPath: parent.path) {
                    do {
                        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                    } catch {
                        return ("Error: Cannot create parent directory \(parent.path): \(error.localizedDescription)", false)
                    }
                }
            }
            guard let data = content.data(using: .utf8) else {
                return ("Error: Content could not be encoded as UTF-8.", false)
            }
            let existed = fm.fileExists(atPath: url.path)
            let before = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            // FileHandle append keeps this O(content) instead of reading the
            // whole file back into memory to concatenate.
            if !existed {
                guard fm.createFile(atPath: url.path, contents: nil) else {
                    return ("Error: Cannot create \(url.path).", false)
                }
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                return ("Error: Cannot open \(url.path) for writing.", false)
            }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                return ("Error: Cannot append to \(url.path): \(error.localizedDescription)", false)
            }
            let after = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return ("Appended \(data.count) bytes to \(url.path)\n"
                    + "size: \(before) → \(after) bytes (\(Self.hostByteSize(after)))"
                    + (existed ? "" : "\ncreated new file"), true)
        }.value
        return FileToolResult(output: Self.hostClamp(result.0, limit: Self.kMaxToolResultChars), success: result.1)
    }

    // MARK: - host_edit_file

    /// Exact-match replacement. Uniqueness is enforced rather than
    /// first-match-wins: a non-unique target almost always means the caller
    /// guessed the surrounding text, and replacing the wrong occurrence of a
    /// guessed fragment is how an edit silently corrupts a file.
    func executeHostEditFile(from json: String) async -> FileToolResult {
        guard let dict = Self.hostArgs(json) else {
            return FileToolResult(output: "Error: arguments were not a JSON object.", success: false)
        }
        let target = hostWriteTarget(from: dict)
        if let error = target.error { return error }
        guard let oldText = dict["old_text"] as? String, !oldText.isEmpty else {
            return FileToolResult(output: "Error: Missing required non-empty 'old_text'.", success: false)
        }
        guard let newText = dict["new_text"] as? String else {
            return FileToolResult(output: "Error: Missing required 'new_text' parameter (pass \"\" to delete the block).", success: false)
        }
        let url = target.url

        let result: (String, Bool) = await Task.detached(priority: .userInitiated) { () -> (String, Bool) in
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return ("Error: No such file (or it is a directory): \(url.path)", false)
            }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return ("Error: Cannot read \(url.path).", false)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return ("Error: \(url.path) is not valid UTF-8; host_edit_file only handles text.", false)
            }
            let occurrences = text.components(separatedBy: oldText).count - 1
            if occurrences == 0 {
                return ("Error: 'old_text' was not found in \(url.path). "
                        + "Read the file first (host_read_file) and copy an exact block.", false)
            }
            if occurrences > 1 {
                return ("Error: 'old_text' appears \(occurrences) times in \(url.path); refusing to guess which one. "
                        + "Include more surrounding lines so the block is unique.", false)
            }
            guard let range = text.range(of: oldText) else {
                return ("Error: 'old_text' matched but could not be located; the file may have changed.", false)
            }
            let updated = text.replacingCharacters(in: range, with: newText)
            guard let outData = updated.data(using: .utf8) else {
                return ("Error: Edited content is not valid UTF-8.", false)
            }
            do {
                try outData.write(to: url, options: .atomic)
            } catch {
                return ("Error: Cannot write \(url.path): \(error.localizedDescription)", false)
            }
            let delta = outData.count - data.count
            let sign = delta >= 0 ? "+" : ""
            return ("Edited \(url.path)\nreplaced 1 occurrence\n"
                    + "size: \(data.count) → \(outData.count) bytes (\(sign)\(delta))", true)
        }.value
        return FileToolResult(output: Self.hostClamp(result.0, limit: Self.kMaxToolResultChars), success: result.1)
    }

    // MARK: - host_delete_file

    func executeHostDeleteFile(from json: String) async -> FileToolResult {
        guard let dict = Self.hostArgs(json) else {
            return FileToolResult(output: "Error: arguments were not a JSON object.", success: false)
        }
        let target = hostWriteTarget(from: dict)
        if let error = target.error { return error }
        let recursive = Self.hostBool(dict["recursive"]) ?? false
        let url = target.url

        let result: (String, Bool) = await Task.detached(priority: .userInitiated) { () -> (String, Bool) in
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return ("Error: Nothing to delete at \(url.path).", false)
            }
            if isDirectory.boolValue {
                // A recursive delete is the most destructive action available
                // here, so it is never the default interpretation of "delete".
                guard recursive else {
                    let count = (try? fm.contentsOfDirectory(atPath: url.path).count) ?? 0
                    return ("Error: \(url.path) is a directory containing \(count) item(s). "
                            + "Pass recursive=true to delete it and everything inside.", false)
                }
                // Do not let `delete .` or a deep ancestor wipe the sandbox by
                // accident: refuse the app container roots and "/" itself.
                let guardPaths = ["/", NSHomeDirectory(),
                                  FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path]
                    .compactMap { $0 }
                if guardPaths.contains(url.path) {
                    return ("Error: Refused to recursively delete \(url.path) — it is a container root.", false)
                }
            }
            do {
                try fm.removeItem(at: url)
            } catch {
                return ("Error: Cannot delete \(url.path): \(error.localizedDescription)", false)
            }
            return ("Deleted \(isDirectory.boolValue ? "directory (recursive)" : "file"): \(url.path)", true)
        }.value
        return FileToolResult(output: Self.hostClamp(result.0, limit: Self.kMaxToolResultChars), success: result.1)
    }

    // MARK: - host_move_file / host_copy_file

    func executeHostMoveFile(from json: String) async -> FileToolResult {
        await hostTransfer(from: json, move: true)
    }

    func executeHostCopyFile(from json: String) async -> FileToolResult {
        await hostTransfer(from: json, move: false)
    }

    /// Shared implementation for move/copy. Both endpoints go through the write
    /// guard: moving a file OUT of a protected area is as much a write as
    /// moving one in.
    private func hostTransfer(from json: String, move: Bool) async -> FileToolResult {
        let verb = move ? "move" : "copy"
        guard let dict = Self.hostArgs(json) else {
            return FileToolResult(output: "Error: arguments were not a JSON object.", success: false)
        }
        // `from` must be readable, so it only needs the READ guard plus a write
        // guard (removal). `to` is purely a write target.
        guard let rawFrom = dict["from"] as? String else {
            return FileToolResult(output: "Error: Missing required 'from' parameter.", success: false)
        }
        guard let rawTo = dict["to"] as? String else {
            return FileToolResult(output: "Error: Missing required 'to' parameter.", success: false)
        }
        let root = (dict["root"] as? String) ?? "ios"
        let allowSystem = Self.hostBool(dict["allow_system"])
            ?? Self.hostBool(dict["allowSystem"])
            ?? false
        let overwrite = Self.hostBool(dict["overwrite"]) ?? false

        let fromResolution = resolveHostWriteTarget(rawFrom, root: root, allowSystem: allowSystem)
        if let error = fromResolution.error {
            return FileToolResult(output: "Error: source — \(error)", success: false)
        }
        let toResolution = resolveHostWriteTarget(rawTo, root: root, allowSystem: allowSystem)
        if let error = toResolution.error {
            return FileToolResult(output: "Error: destination — \(error)", success: false)
        }
        guard let fromURL = fromResolution.url, let toURL = toResolution.url else {
            return FileToolResult(output: "Error: Unresolved \(move ? "move" : "copy") path.", success: false)
        }

        let result: (String, Bool) = await Task.detached(priority: .userInitiated) { () -> (String, Bool) in
            let fm = FileManager.default
            guard fm.fileExists(atPath: fromURL.path) else {
                return ("Error: Source does not exist: \(fromURL.path)", false)
            }
            if fm.fileExists(atPath: toURL.path) && !overwrite {
                return ("Error: Destination already exists: \(toURL.path). Pass overwrite=true to replace it.", false)
            }
            let parent = toURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                do {
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                } catch {
                    return ("Error: Cannot create \(parent.path): \(error.localizedDescription)", false)
                }
            }
            do {
                // Replace semantics so overwrite=true actually overwrites.
                if fm.fileExists(atPath: toURL.path) { try fm.removeItem(at: toURL) }
                if move {
                    try fm.moveItem(at: fromURL, to: toURL)
                } else {
                    try fm.copyItem(at: fromURL, to: toURL)
                }
            } catch {
                return ("Error: Cannot \(verb) \(fromURL.path) → \(toURL.path): \(error.localizedDescription)", false)
            }
            let size = (try? toURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return ("\(move ? "Moved" : "Copied") \(fromURL.path)\n"
                    + "  → \(toURL.path)\n"
                    + "size: \(size) bytes (\(Self.hostByteSize(size)))", true)
        }.value
        return FileToolResult(output: Self.hostClamp(result.0, limit: Self.kMaxToolResultChars), success: result.1)
    }
}
