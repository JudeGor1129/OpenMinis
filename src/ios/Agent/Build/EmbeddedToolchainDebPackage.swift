import Foundation

/// User-owned project metadata. Debian architecture describes the bootstrap,
/// not the dylib slices: a rootless arm64+arm64e tweak uses iphoneos-arm64.
struct EmbeddedDebMetadata: Codable, Equatable, Sendable {
    let packageID: String
    let name: String
    let version: String
    let maintainer: String
    let description: String
    let tweakName: String
    let bundleIDs: [String]

    func validate() throws {
        func matches(_ text: String, _ regex: String) -> Bool {
            guard let range = text.range(of: regex, options: .regularExpression) else { return false }
            return range == (text.startIndex..<text.endIndex)
        }
        func singleLine(_ text: String) -> Bool {
            !text.isEmpty && text.utf8.count <= 256 &&
                text.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
                }
        }
        guard matches(packageID, "^[a-z0-9][a-z0-9+.-]{1,127}$"),
              matches(version, "^[0-9][A-Za-z0-9.+~_-]{0,63}$"),
              matches(tweakName, "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"),
              singleLine(name), singleLine(maintainer), singleLine(description),
              !bundleIDs.isEmpty, bundleIDs.count <= 20, Set(bundleIDs).count == bundleIDs.count,
              bundleIDs.allSatisfy({ matches($0, "^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$") }) else {
            throw EmbeddedAdapterError.rejected("invalid or unbounded rootless package metadata/filter")
        }
        let filenameBytes = (packageID + "_" + version + "_iphoneos-arm64.deb").utf8.count
        guard filenameBytes <= 255 else {
            throw EmbeddedAdapterError.rejected("rootless package filename exceeds the filesystem component limit")
        }
    }
    var dylibName: String { tweakName + ".dylib" }
    var filename: String { packageID + "_" + version + "_iphoneos-arm64.deb" }
    var payloadDirectory: String { "var/jb/Library/MobileSubstrate/DynamicLibraries" }
    var control: Data {
        Data(("Package: \(packageID)\nName: \(name)\nVersion: \(version)\n" +
              "Architecture: iphoneos-arm64\nMaintainer: \(maintainer)\n" +
              "Description: \(description)\nSection: Tweaks\nPriority: optional\n" +
              "Depends: firmware (>= 15.0), mobilesubstrate\n").utf8)
    }
    func filter() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["Filter": ["Bundles": bundleIDs]],
                                            format: .xml, options: 0)
    }
}

/// Fixed-name project manifest consumed only by the native embedded provider.
/// It contains package metadata, never commands, paths or toolchain arguments.
struct EmbeddedToolchainTweakManifest: Codable, Equatable, Sendable {
    static let filename = "MinisTweak.json"
    static let maxBytes = 16 * 1024
    let schema: Int
    let package: EmbeddedDebMetadata

    func validate() throws {
        guard schema == 1 else { throw EmbeddedAdapterError.rejected("unsupported MinisTweak.json schema") }
        try package.validate()
    }

    static func load(from projectRoot: URL) throws -> EmbeddedToolchainTweakManifest {
        let data = try EmbeddedToolchainProjectSnapshotBuilder.readBoundedProjectFile(
            filename, root: projectRoot, limit: maxBytes)
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        try manifest.validate()
        return manifest
    }
}

struct EmbeddedDebArtifact: Codable, Equatable, Sendable {
    let filename: String
    let bytes: Int
    let sha256: String
    let payloadPath: String
    let universal: EmbeddedUniversalArtifact
}

/// Pure-memory Debian 2.0 package creation. No shell, Makefile, maintainer
/// scripts, external files, loading or installation. Uncompressed ustar members
/// are standard DEB members; package tools independently validate them in CI.
enum EmbeddedToolchainDebPackage {
    static let maxBytes = EmbeddedToolchainUniversalBinary.maxBytes + 1024 * 1024
    static func build(dylib: Data, metadata: EmbeddedDebMetadata,
                      cancellation: EmbeddedAdapterCancellation = EmbeddedAdapterCancellation()) throws -> Data {
        try metadata.validate()
        guard !cancellation.isCancelled else { throw CancellationError() }
        _ = try EmbeddedToolchainUniversalBinary.inspect(dylib, name: metadata.dylibName)
        let prefix = metadata.payloadDirectory
        let directories = ["var", "var/jb", "var/jb/Library", "var/jb/Library/MobileSubstrate", prefix]
        var entries = directories.map { PackageTarEntry(path: $0, bytes: Data(), directory: true, mode: 0o755) }
        entries.append(PackageTarEntry(path: prefix + "/" + metadata.dylibName, bytes: dylib, directory: false, mode: 0o755))
        entries.append(PackageTarEntry(path: prefix + "/" + metadata.tweakName + ".plist",
                                       bytes: try metadata.filter(), directory: false, mode: 0o644))
        let control = try PackageArchive.tar([PackageTarEntry(path: "control", bytes: metadata.control,
                                                              directory: false, mode: 0o644)])
        let payload = try PackageArchive.tar(entries)
        let deb = try PackageArchive.ar([("debian-binary", Data("2.0\n".utf8)), ("control.tar", control), ("data.tar", payload)])
        guard deb.count <= maxBytes else { throw EmbeddedAdapterError.rejected("DEB exceeds byte budget") }
        guard !cancellation.isCancelled else { throw CancellationError() }
        _ = try inspect(deb, metadata: metadata)
        return deb
    }

    static func inspect(_ deb: Data, metadata: EmbeddedDebMetadata) throws -> EmbeddedDebArtifact {
        try metadata.validate()
        guard deb.count <= maxBytes else { throw EmbeddedAdapterError.rejected("DEB exceeds byte budget") }
        let archives = try PackageArchive.readAr(deb)
        guard archives.map(\.0) == ["debian-binary", "control.tar", "data.tar"],
              archives[0].1 == Data("2.0\n".utf8) else {
            throw EmbeddedAdapterError.rejected("noncanonical DEB members/version")
        }
        let control = try PackageArchive.readTar(archives[1].1)
        guard control.count == 1, control[0].path == "control", !control[0].directory,
              control[0].mode == 0o644, control[0].bytes == metadata.control else {
            throw EmbeddedAdapterError.rejected("DEB control differs from validated metadata")
        }
        let payload = try PackageArchive.readTar(archives[2].1)
        let expectedFilter = try metadata.filter()
        let prefix = metadata.payloadDirectory
        let expectedPaths = ["var", "var/jb", "var/jb/Library", "var/jb/Library/MobileSubstrate", prefix,
                             prefix + "/" + metadata.dylibName, prefix + "/" + metadata.tweakName + ".plist"]
        guard payload.map(\.path) == expectedPaths,
              payload.prefix(5).allSatisfy({ $0.directory && $0.mode == 0o755 && $0.bytes.isEmpty }),
              !payload[5].directory, payload[5].mode == 0o755,
              !payload[6].directory, payload[6].mode == 0o644,
              payload[6].bytes == expectedFilter else {
            throw EmbeddedAdapterError.rejected("DEB payload/filter/path/permissions mismatch")
        }
        let universal = try EmbeddedToolchainUniversalBinary.inspect(payload[5].bytes, name: metadata.dylibName)
        return EmbeddedDebArtifact(filename: metadata.filename, bytes: deb.count,
            sha256: EmbeddedAdapterArtifact.digest(deb), payloadPath: expectedPaths[5], universal: universal)
    }
}

struct EmbeddedTheosDebEntry: Equatable, Sendable {
    let path: String
    let bytes: Data
    let mode: Int
}

enum EmbeddedTheosDebPackageError: Error, Equatable, LocalizedError, Sendable {
    case invalidMetadata
    case unsafePath(String)
    case emptyPayload
    case tooLarge
    case invalidPackage(String)

    var errorDescription: String? {
        switch self {
        case .invalidMetadata: return "Theos package metadata is invalid or unbounded"
        case .unsafePath(let path): return "Theos package payload path is not rootless-safe: \(path)"
        case .emptyPayload: return "Theos package has no payload files"
        case .tooLarge: return "Theos package exceeds the byte budget"
        case .invalidPackage(let detail): return "Theos package structure is invalid: \(detail)"
        }
    }
}

/// Multi-target rootless DEB assembly for Theos-style projects: daemon executable,
/// SpringBoard tweak dylib, filter plist, LaunchDaemon plist and optional maintainer
/// scripts. It builds bytes only - nothing is installed, signed or executed, and
/// maintainer scripts are packaged verbatim, never run inside the app.
enum EmbeddedTheosDebPackage {
    static let maxBytes = 48 * 1024 * 1024
    static let rootlessPrefix = "var/jb/"

    static func control(packageID: String, name: String, version: String,
                        maintainer: String, description: String,
                        depends: String) throws -> String {
        func singleLine(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 256 &&
                value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
        guard packageID.range(of: "^[a-z0-9][a-z0-9+.-]{1,127}$", options: .regularExpression) != nil,
              version.range(of: "^[0-9][A-Za-z0-9.+~_-]{0,63}$", options: .regularExpression) != nil,
              singleLine(name), singleLine(maintainer), singleLine(description),
              singleLine(depends) else {
            throw EmbeddedTheosDebPackageError.invalidMetadata
        }
        return "Package: \(packageID)\nName: \(name)\nVersion: \(version)\n" +
            "Architecture: iphoneos-arm64\nMaintainer: \(maintainer)\n" +
            "Description: \(description)\nSection: Tweaks\nPriority: optional\n" +
            "Depends: \(depends)\n"
    }

    static func build(files: [EmbeddedTheosDebEntry], controlText: String,
                      maintainerScripts: [String: String] = [:]) throws -> Data {
        guard !files.isEmpty else { throw EmbeddedTheosDebPackageError.emptyPayload }
        var seen = Set<String>()
        for file in files {
            try validate(file.path)
            guard seen.insert(file.path).inserted, (0...0o777).contains(file.mode), !file.bytes.isEmpty else {
                throw EmbeddedTheosDebPackageError.unsafePath(file.path)
            }
        }
        for (name, body) in maintainerScripts {
            guard ["postinst", "prerm"].contains(name), !body.isEmpty, body.utf8.count <= 64 * 1024 else {
                throw EmbeddedTheosDebPackageError.invalidPackage("maintainer script \(name)")
            }
        }

        var directories = Set<String>()
        for file in files {
            var components = file.path.split(separator: "/").dropLast()
            while !components.isEmpty {
                directories.insert(components.joined(separator: "/"))
                components = components.dropLast()
            }
        }
        var entries = directories.sorted().map {
            PackageTarEntry(path: $0, bytes: Data(), directory: true, mode: 0o755)
        }
        entries.append(contentsOf: files.sorted { $0.path < $1.path }.map {
            PackageTarEntry(path: $0.path, bytes: $0.bytes, directory: false, mode: $0.mode)
        })

        var controlEntries = [PackageTarEntry(path: "control", bytes: Data(controlText.utf8),
                                             directory: false, mode: 0o644)]
        for name in ["postinst", "prerm"] {
            if let body = maintainerScripts[name] {
                controlEntries.append(PackageTarEntry(path: name, bytes: Data(body.utf8),
                                                      directory: false, mode: 0o755))
            }
        }

        let control = try PackageArchive.tar(controlEntries)
        let payload = try PackageArchive.tar(entries)
        let deb = try PackageArchive.ar([("debian-binary", Data("2.0\n".utf8)),
                                         ("control.tar", control), ("data.tar", payload)])
        guard deb.count <= maxBytes else { throw EmbeddedTheosDebPackageError.tooLarge }
        _ = try inspect(deb)
        return deb
    }

    /// Structural read-back: verifies ar members, control layout and that every
    /// payload file stays inside the rootless /var/jb prefix.
    @discardableResult
    static func inspect(_ deb: Data) throws -> [String] {
        guard deb.count <= maxBytes else { throw EmbeddedTheosDebPackageError.tooLarge }
        let archives = try PackageArchive.readAr(deb)
        guard archives.map(\.0) == ["debian-binary", "control.tar", "data.tar"],
              archives[0].1 == Data("2.0\n".utf8) else {
            throw EmbeddedTheosDebPackageError.invalidPackage("ar members or version")
        }
        let control = try PackageArchive.readTar(archives[1].1)
        guard control.first?.path == "control", control.first?.mode == 0o644, control.first?.directory == false,
              control.dropFirst().allSatisfy({ ["postinst", "prerm"].contains($0.path) && $0.mode == 0o755 }),
              control.count <= 3 else {
            throw EmbeddedTheosDebPackageError.invalidPackage("control.tar layout")
        }
        let payload = try PackageArchive.readTar(archives[2].1)
        guard !payload.isEmpty else { throw EmbeddedTheosDebPackageError.emptyPayload }
        for entry in payload where !entry.directory {
            guard entry.path.hasPrefix(rootlessPrefix), entry.mode == 0o755 || entry.mode == 0o644 else {
                throw EmbeddedTheosDebPackageError.invalidPackage("payload file \(entry.path)")
            }
        }
        return payload.map(\.path)
    }

    private static func validate(_ path: String) throws {
        guard path.hasPrefix(rootlessPrefix), !path.hasSuffix("/"), !path.contains("//"),
              path.utf8.count <= 200, !path.contains("\\") else {
            throw EmbeddedTheosDebPackageError.unsafePath(path)
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw EmbeddedTheosDebPackageError.unsafePath(path)
        }
    }
}

/// Theos/Debian `control` metadata parsed declaratively. Only a fixed set of
/// fields is read; no variable substitution, shell text or recipe is evaluated.
struct EmbeddedTheosControlMetadata: Equatable, Sendable {
    static let maxBytes = 16 * 1024
    static let defaultDepends = "firmware (>= 15.4), mobilesubstrate"

    let packageID: String
    let name: String
    let version: String
    let maintainer: String
    let description: String
    let depends: String

    static func parse(_ text: String) throws -> EmbeddedTheosControlMetadata {
        guard text.utf8.count <= maxBytes else { throw EmbeddedTheosDebPackageError.invalidMetadata }
        var fields: [String: String] = [:]
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty { continue }
            // Continuation lines belong to a field this parser deliberately ignores.
            if line.hasPrefix(" ") || line.hasPrefix("\t") { continue }
            guard let colon = line.firstIndex(of: ":") else { throw EmbeddedTheosDebPackageError.invalidMetadata }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty,
                  key.range(of: "^[A-Za-z][A-Za-z0-9-]{0,31}$", options: .regularExpression) != nil else {
                throw EmbeddedTheosDebPackageError.invalidMetadata
            }
            fields[key] = value
        }
        func singleLine(_ value: String, _ limit: Int) -> Bool {
            !value.isEmpty && value.utf8.count <= limit && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
            }
        }
        guard let packageID = fields["Package"],
              packageID.range(of: "^[a-z0-9][a-z0-9+.-]{1,127}$", options: .regularExpression) != nil,
              let name = fields["Name"], singleLine(name, 256),
              let version = fields["Version"],
              version.range(of: "^[0-9][A-Za-z0-9.+~_-]{0,63}$", options: .regularExpression) != nil,
              let maintainer = fields["Maintainer"], singleLine(maintainer, 256),
              let description = fields["Description"], singleLine(description, 512) else {
            throw EmbeddedTheosDebPackageError.invalidMetadata
        }
        let depends = fields["Depends"].flatMap { singleLine($0, 256) ? $0 : nil } ?? defaultDepends
        return EmbeddedTheosControlMetadata(packageID: packageID, name: name, version: version,
                                            maintainer: maintainer, description: description, depends: depends)
    }

    var filename: String { packageID + "_" + version + "_iphoneos-arm64.deb" }

    var controlText: String {
        "Package: \(packageID)\nName: \(name)\nVersion: \(version)\n" +
            "Architecture: iphoneos-arm64\nMaintainer: \(maintainer)\n" +
            "Description: \(description)\nSection: Tweaks\nPriority: optional\n" +
            "Depends: \(depends)\n"
    }
}

/// Reads the SpringBoard filter bundles a tweak declares in its own plist.
enum EmbeddedTheosFilterPlist {
    static let maxBytes = 16 * 1024

    static func bundleIDs(from data: Data) throws -> [String] {
        guard !data.isEmpty, data.count <= maxBytes else { throw EmbeddedTheosDebPackageError.invalidMetadata }
        let object: Any
        do { object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
        catch { throw EmbeddedTheosDebPackageError.invalidMetadata }
        guard let dictionary = object as? [String: Any],
              let filter = dictionary["Filter"] as? [String: Any],
              let bundles = filter["Bundles"] as? [String], !bundles.isEmpty, bundles.count <= 20,
              Set(bundles).count == bundles.count,
              bundles.allSatisfy({ $0.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$",
                                            options: .regularExpression) != nil }) else {
            throw EmbeddedTheosDebPackageError.invalidMetadata
        }
        return bundles
    }
}

struct EmbeddedTheosLayoutEntry: Equatable, Sendable {
    /// Path relative to the rootless prefix, e.g. "Library/LaunchDaemons/a.plist".
    let path: String
    let bytes: Data
    let mode: Int
}

/// Reads the project's `layout/` staging tree - the documented Theos way to ship
/// extra files such as LaunchDaemon plists - without executing anything. Every
/// file is re-read through the bounded O_NOFOLLOW project reader, so a symlink or
/// oversized file is rejected rather than trusted.
enum EmbeddedTheosLayoutLoader {
    static let directory = "layout"
    static let maxFiles = 256
    static let maxFileBytes = 16 * 1024
    static let maxTotalBytes = 4 * 1024 * 1024

    static func load(root: URL) throws -> [EmbeddedTheosLayoutEntry] {
        let canonical = try EmbeddedToolchainProjectSnapshotBuilder.validatedRoot(root)
        let base = canonical.appendingPathComponent(directory, isDirectory: true)
        var isDirectoryFlag: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectoryFlag) else { return [] }
        guard isDirectoryFlag.boolValue else { throw EmbeddedTheosDebPackageError.unsafePath(directory) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles], errorHandler: nil) else {
            throw EmbeddedTheosDebPackageError.unsafePath(directory)
        }
        var relatives: [String] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                throw EmbeddedTheosDebPackageError.unsafePath(url.lastPathComponent)
            }
            if values.isSymbolicLink == true { throw EmbeddedTheosDebPackageError.unsafePath(url.lastPathComponent) }
            guard values.isRegularFile == true else { continue }
            let pathPrefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
            guard url.path.hasPrefix(pathPrefix) else {
                throw EmbeddedTheosDebPackageError.unsafePath(url.lastPathComponent)
            }
            let relative = "\(directory)/\(url.path.dropFirst(pathPrefix.count))"
            relatives.append(relative)
            guard relatives.count <= maxFiles else { throw EmbeddedTheosDebPackageError.tooLarge }
        }
        var entries: [EmbeddedTheosLayoutEntry] = []
        var total = 0
        for relative in relatives.sorted() {
            let stripped = String(relative.dropFirst(directory.count + 1))
            guard !stripped.isEmpty else { throw EmbeddedTheosDebPackageError.unsafePath(relative) }
            guard stripped != "DEBIAN", !stripped.hasPrefix("DEBIAN/") else {
                throw EmbeddedTheosDebPackageError.invalidPackage("layout/DEBIAN maintainer scripts are not supported")
            }
            let bytes = try EmbeddedToolchainProjectSnapshotBuilder.readBoundedProjectFile(
                relative, root: canonical, limit: maxFileBytes)
            guard !bytes.isEmpty, total <= maxTotalBytes - bytes.count else {
                throw EmbeddedTheosDebPackageError.tooLarge
            }
            total += bytes.count
            entries.append(EmbeddedTheosLayoutEntry(path: stripped, bytes: bytes,
                                                    mode: try mode(of: relative, root: canonical)))
        }
        return entries
    }

    private static func mode(of relative: String, root: URL) throws -> Int {
        let url = root.appendingPathComponent(relative)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        guard permissions == 0o755 || permissions == 0o644 else {
            throw EmbeddedTheosDebPackageError.invalidPackage("layout file mode must be 0755 or 0644: \(relative)")
        }
        return permissions
    }
}

private struct PackageTarEntry {
    let path: String
    let bytes: Data
    let directory: Bool
    let mode: Int
}

private enum PackageArchive {
    static func invalid() -> EmbeddedAdapterError { .rejected("malformed or unsupported DEB/ar/ustar structure") }
    static func field(_ string: String, length: Int, pad: UInt8 = 0) throws -> Data {
        let bytes = Data(string.utf8)
        guard bytes.count <= length else { throw invalid() }
        return bytes + Data(repeating: pad, count: length - bytes.count)
    }
    static func number(_ value: Int, length: Int) throws -> Data {
        guard value >= 0 else { throw invalid() }
        let text = String(value, radix: 8)
        guard text.count < length else { throw invalid() }
        return Data((String(repeating: "0", count: length - 1 - text.count) + text + "\0").utf8)
    }
    static func text(_ bytes: Data) throws -> String {
        guard let text = String(data: bytes.prefix(while: { $0 != 0 }), encoding: .utf8) else { throw invalid() }
        return text
    }
    static func parsedNumber(_ bytes: Data, radix: Int) throws -> Int {
        let value = try text(bytes).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, let number = Int(value, radix: radix), number >= 0 else { throw invalid() }
        return number
    }
    static func tar(_ entries: [PackageTarEntry]) throws -> Data {
        var output = Data()
        for entry in entries {
            var header = Data(repeating: 0, count: 512)
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw invalid() }
            let name = String(components.last!)
            let prefix = components.dropLast().joined(separator: "/")
            func put(_ data: Data, at offset: Int) { header.replaceSubrange(offset..<(offset + data.count), with: data) }
            put(try field(name, length: 100), at: 0)
            put(try number(entry.mode, length: 8), at: 100)
            put(try number(0, length: 8), at: 108)
            put(try number(0, length: 8), at: 116)
            put(try number(entry.bytes.count, length: 12), at: 124)
            put(try number(0, length: 12), at: 136)
            put(Data(repeating: 32, count: 8), at: 148)
            header[156] = entry.directory ? 53 : 48
            put(Data("ustar\0".utf8), at: 257)
            put(Data("00".utf8), at: 263)
            put(try field("root", length: 32), at: 265)
            put(try field("root", length: 32), at: 297)
            put(try number(0, length: 8), at: 329)
            put(try number(0, length: 8), at: 337)
            put(try field(prefix, length: 155), at: 345)
            let sum = header.reduce(0) { $0 + Int($1) }
            put(try number(sum, length: 7) + Data([32]), at: 148)
            output.append(header); output.append(entry.bytes)
            output.append(Data(repeating: 0, count: (512 - entry.bytes.count % 512) % 512))
            guard output.count <= EmbeddedToolchainDebPackage.maxBytes else { throw invalid() }
        }
        output.append(Data(repeating: 0, count: 1024))
        return output
    }
    static func readTar(_ data: Data) throws -> [PackageTarEntry] {
        guard data.count >= 1024, data.count % 512 == 0 else { throw invalid() }
        var entries: [PackageTarEntry] = []
        var cursor = 0
        var paths: Set<String> = []
        while cursor + 512 <= data.count {
            var header = Data(data[cursor..<(cursor + 512)])
            if header.allSatisfy({ $0 == 0 }) {
                guard data.count - cursor >= 1024, data[cursor...].allSatisfy({ $0 == 0 }) else { throw invalid() }
                return entries
            }
            guard entries.count < 64, header[257..<263] == Data("ustar\0".utf8),
                  header[263..<265] == Data("00".utf8), [UInt8(48), 53].contains(header[156]),
                  header[157..<257].allSatisfy({ $0 == 0 }),
                  try parsedNumber(Data(header[108..<116]), radix: 8) == 0,
                  try parsedNumber(Data(header[116..<124]), radix: 8) == 0 else { throw invalid() }
            let expectedChecksum = try parsedNumber(Data(header[148..<156]), radix: 8)
            header.replaceSubrange(148..<156, with: Data(repeating: 32, count: 8))
            guard expectedChecksum == header.reduce(0, { $0 + Int($1) }) else { throw invalid() }
            let prefix = try text(Data(header[345..<500]))
            let basename = try text(Data(header[0..<100]))
            let path = prefix.isEmpty ? basename : prefix + "/" + basename
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), paths.insert(path).inserted else { throw invalid() }
            let count = try parsedNumber(Data(header[124..<136]), radix: 8)
            let mode = try parsedNumber(Data(header[100..<108]), radix: 8)
            cursor += 512
            guard count <= data.count - cursor else { throw invalid() }
            let bytes = Data(data[cursor..<(cursor + count)])
            let padding = (512 - count % 512) % 512
            guard padding <= data.count - cursor - count,
                  data[(cursor + count)..<(cursor + count + padding)].allSatisfy({ $0 == 0 }) else { throw invalid() }
            let directory = header[156] == 53
            guard !directory || count == 0 else { throw invalid() }
            entries.append(PackageTarEntry(path: path, bytes: bytes, directory: directory, mode: mode))
            cursor += count + padding
        }
        throw invalid()
    }
    static func ar(_ members: [(String, Data)]) throws -> Data {
        var output = Data("!<arch>\n".utf8)
        for (name, bytes) in members {
            output.append(try field(name + "/", length: 16, pad: 32))
            output.append(try field("0", length: 12, pad: 32))
            output.append(try field("0", length: 6, pad: 32))
            output.append(try field("0", length: 6, pad: 32))
            output.append(try field("100644", length: 8, pad: 32))
            output.append(try field(String(bytes.count), length: 10, pad: 32))
            output.append(Data("`\n".utf8)); output.append(bytes)
            if bytes.count % 2 == 1 { output.append(10) }
        }
        return output
    }
    static func readAr(_ data: Data) throws -> [(String, Data)] {
        guard data.count >= 8, data.prefix(8) == Data("!<arch>\n".utf8) else { throw invalid() }
        var cursor = 8
        var members: [(String, Data)] = []
        while cursor < data.count {
            guard members.count < 3, data.count - cursor >= 60 else { throw invalid() }
            let header = Data(data[cursor..<(cursor + 60)])
            guard header.suffix(2) == Data("`\n".utf8) else { throw invalid() }
            let name = try text(Data(header.prefix(16))).trimmingCharacters(in: .whitespaces)
            guard name.hasSuffix("/") else { throw invalid() }
            let count = try parsedNumber(Data(header[48..<58]), radix: 10)
            cursor += 60
            guard count <= data.count - cursor else { throw invalid() }
            members.append((String(name.dropLast()), Data(data[cursor..<(cursor + count)])))
            cursor += count
            if count % 2 == 1 {
                guard cursor < data.count, data[cursor] == 10 else { throw invalid() }
                cursor += 1
            }
        }
        guard members.count == 3 else { throw invalid() }
        return members
    }
}
