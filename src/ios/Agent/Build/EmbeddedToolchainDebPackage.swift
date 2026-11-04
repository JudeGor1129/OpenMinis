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
            guard entries.count < 8, header[257..<263] == Data("ustar\0".utf8),
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
