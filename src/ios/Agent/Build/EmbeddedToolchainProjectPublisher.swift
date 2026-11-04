import Foundation
import CryptoKit
import Darwin

struct EmbeddedToolchainPublishedArtifact: Codable, Equatable, Sendable {
    let relativePath: String
    let bytes: Int
    let sha256: String
    let architecture: String
    let filetype: UInt32
    let artifactKind: String
    /// A rename has committed even if the following directory fsync fails.
    let directorySynced: Bool
}

enum EmbeddedToolchainProjectPublisherError: Error, Equatable, LocalizedError, Sendable {
    case invalidRoot(String)
    case unsafeName
    case outputTooLarge
    case invalidMachO
    case invalidPackage
    case directoryCreateFailed(Int32)
    case fileCreateFailed(Int32)
    case writeFailed(Int32)
    case syncFailed(Int32)
    case replaceFailed(Int32)
    case readBackFailed(Int32)
    case committedButUnverified(String, directorySynced: Bool)

    var errorDescription: String? {
        switch self {
        case .invalidRoot(let reason): return "selected project root rejected: " + reason
        case .unsafeName: return "output name is not a safe or filesystem-bounded filename"
        case .outputTooLarge: return "verified artifact exceeds the publication byte budget"
        case .invalidMachO: return "refusing to publish a dylib that fails Mach-O inspection"
        case .invalidPackage: return "refusing to publish a DEB that fails package inspection"
        case .directoryCreateFailed(let code): return "cannot create project build directory (errno \(code))"
        case .fileCreateFailed(let code): return "cannot create temporary build output (errno \(code))"
        case .writeFailed(let code): return "cannot write verified output (errno \(code))"
        case .syncFailed(let code): return "cannot sync verified output (errno \(code))"
        case .replaceFailed(let code): return "cannot atomically publish verified output (errno \(code))"
        case .readBackFailed(let code): return "published output could not be read back safely (errno \(code))"
        case .committedButUnverified(let reason, let synced):
            return "destination rename committed, but final verification failed (directory synced: \(synced)): \(reason)"
        }
    }
}

/// Publishes only a dylib byte buffer produced by a successful restricted
/// adapter request. It writes under the user-selected project root after an
/// explicit Build action, atomically replacing the project-local output.
/// It never loads, signs, installs, or executes the generated dylib.
enum EmbeddedToolchainProjectPublisher {
    static let maxDylibBytes = 16 * 1024 * 1024
    static let outputDirectory = "build/minis-embedded"

    static func publishVerifiedDylib(_ data: Data, named name: String,
                                     projectRoot: URL,
                                     cancellation: EmbeddedAdapterCancellation = EmbeddedAdapterCancellation()) throws -> EmbeddedToolchainPublishedArtifact {
        guard safeDylibFilename(name) else { throw EmbeddedToolchainProjectPublisherError.unsafeName }
        guard data.count <= maxDylibBytes else { throw EmbeddedToolchainProjectPublisherError.outputTooLarge }
        guard !cancellation.isCancelled else { throw CancellationError() }
        do { _ = try EmbeddedAdapterArtifact.inspect(data, name: name, filetype: 6) }
        catch { throw EmbeddedToolchainProjectPublisherError.invalidMachO }
        return try publishVerifiedBytes(data, named: name, architecture: "arm64", filetype: 6,
            kind: "dylib", maximumBytes: maxDylibBytes, projectRoot: projectRoot,
            cancellation: cancellation)
    }

    static func publishVerifiedUniversalDylib(_ data: Data, named name: String,
                                              projectRoot: URL,
                                              cancellation: EmbeddedAdapterCancellation = EmbeddedAdapterCancellation()) throws -> EmbeddedToolchainPublishedArtifact {
        guard safeDylibFilename(name) else { throw EmbeddedToolchainProjectPublisherError.unsafeName }
        guard data.count <= EmbeddedToolchainUniversalBinary.maxBytes else { throw EmbeddedToolchainProjectPublisherError.outputTooLarge }
        guard !cancellation.isCancelled else { throw CancellationError() }
        do { _ = try EmbeddedToolchainUniversalBinary.inspect(data, name: name) }
        catch { throw EmbeddedToolchainProjectPublisherError.invalidMachO }
        return try publishVerifiedBytes(data, named: name, architecture: "arm64+arm64e", filetype: 6,
            kind: "universal_dylib", maximumBytes: EmbeddedToolchainUniversalBinary.maxBytes,
            projectRoot: projectRoot, cancellation: cancellation)
    }

    static func publishRootlessDeb(_ data: Data, metadata: EmbeddedDebMetadata,
                                   projectRoot: URL,
                                   cancellation: EmbeddedAdapterCancellation = EmbeddedAdapterCancellation()) throws -> EmbeddedToolchainPublishedArtifact {
        let name = metadata.filename
        guard safeDebFilename(name) else { throw EmbeddedToolchainProjectPublisherError.unsafeName }
        guard data.count <= EmbeddedToolchainDebPackage.maxBytes else { throw EmbeddedToolchainProjectPublisherError.outputTooLarge }
        guard !cancellation.isCancelled else { throw CancellationError() }
        do { _ = try EmbeddedToolchainDebPackage.inspect(data, metadata: metadata) }
        catch { throw EmbeddedToolchainProjectPublisherError.invalidPackage }
        return try publishVerifiedBytes(data, named: name, architecture: "iphoneos-arm64", filetype: 0,
            kind: "rootless_deb", maximumBytes: EmbeddedToolchainDebPackage.maxBytes,
            projectRoot: projectRoot, cancellation: cancellation)
    }

    private static func publishVerifiedBytes(_ data: Data, named name: String,
                                             architecture: String, filetype: UInt32, kind: String,
                                             maximumBytes: Int, projectRoot: URL,
                                             cancellation: EmbeddedAdapterCancellation) throws -> EmbeddedToolchainPublishedArtifact {
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard safeOutputFilename(name) else { throw EmbeddedToolchainProjectPublisherError.unsafeName }
        guard !data.isEmpty, data.count <= maximumBytes else { throw EmbeddedToolchainProjectPublisherError.outputTooLarge }
        let root: URL
        do { root = try EmbeddedToolchainProjectSnapshotBuilder.validatedRoot(projectRoot) }
        catch { throw EmbeddedToolchainProjectPublisherError.invalidRoot("project selection: \(error.localizedDescription)") }
        guard isSafeRoot(root), isDirectory(root) else {
            throw EmbeddedToolchainProjectPublisherError.invalidRoot("unsafe/non-directory physical root \(root.path)")
        }
        let rootFD = try openCanonicalDirectory(root)
        defer { close(rootFD) }
        let buildFD = try openOrCreateDirectory("build", under: rootFD)
        defer { close(buildFD) }
        let outputFD = try openOrCreateDirectory("minis-embedded", under: buildFD)
        defer { close(outputFD) }

        let temporary = ".minis-\(UUID().uuidString).tmp"
        let tempFD = temporary.withCString {
            openat(outputFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard tempFD >= 0 else { throw EmbeddedToolchainProjectPublisherError.fileCreateFailed(errno) }
        var tempExists = true
        defer {
            close(tempFD)
            if tempExists { _ = temporary.withCString { unlinkat(outputFD, $0, 0) } }
        }
        try writeAll(data, to: tempFD)
        guard fsync(tempFD) == 0 else { throw EmbeddedToolchainProjectPublisherError.syncFailed(errno) }
        try cancellation.commitIfNotCancelled {
            let renamed = temporary.withCString { source in
                name.withCString { destination in renameat(outputFD, source, outputFD, destination) }
            }
            guard renamed == 0 else { throw EmbeddedToolchainProjectPublisherError.replaceFailed(errno) }
            tempExists = false
        }
        let directorySynced = fsync(outputFD) == 0
        do {
            let hash = try readBackVerified(data, named: name, under: outputFD, publishedDescriptor: tempFD)
            guard directoryEntryMatches(rootFD, name: "build", descriptor: buildFD),
                  directoryEntryMatches(buildFD, name: "minis-embedded", descriptor: outputFD) else {
                throw EmbeddedToolchainProjectPublisherError.readBackFailed(EIO)
            }
            let currentRootFD = try openCanonicalDirectory(root)
            defer { close(currentRootFD) }
            guard sameDirectoryIdentity(rootFD, currentRootFD) else {
                throw EmbeddedToolchainProjectPublisherError.readBackFailed(EIO)
            }
            return EmbeddedToolchainPublishedArtifact(relativePath: "\(outputDirectory)/\(name)",
                bytes: data.count, sha256: hash, architecture: architecture, filetype: filetype,
                artifactKind: kind, directorySynced: directorySynced)
        } catch {
            throw EmbeddedToolchainProjectPublisherError.committedButUnverified(
                error.localizedDescription, directorySynced: directorySynced)
        }
    }

    /// Read the final directory entry, not the original in-memory buffer. The
    /// write descriptor pins the inode that rename committed; fstatat also
    /// rejects replacement/unlink while the bounded streaming read is in flight.
    /// After rename there are deliberately no cancellation checks: commit won.
    static func readBackVerified(_ expected: Data, named name: String, under directory: Int32,
                                 publishedDescriptor: Int32) throws -> String {
        guard safeOutputFilename(name), !expected.isEmpty,
              expected.count <= EmbeddedToolchainDebPackage.maxBytes else {
            throw EmbeddedToolchainProjectPublisherError.readBackFailed(EINVAL)
        }
        let descriptor = name.withCString {
            openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw EmbeddedToolchainProjectPublisherError.readBackFailed(errno) }
        defer { close(descriptor) }
        var committed = stat()
        var before = stat()
        guard fstat(publishedDescriptor, &committed) == 0, fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size == off_t(expected.count), before.st_nlink > 0,
              committed.st_dev == before.st_dev, committed.st_ino == before.st_ino,
              committed.st_size == before.st_size else {
            throw EmbeddedToolchainProjectPublisherError.readBackFailed(EIO)
        }
        var digest = SHA256()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw EmbeddedToolchainProjectPublisherError.readBackFailed(errno) }
            if count == 0 { break }
            guard count <= expected.count - total else {
                throw EmbeddedToolchainProjectPublisherError.readBackFailed(EIO)
            }
            let block = Data(buffer[0..<count])
            guard expected[total..<(total + count)].elementsEqual(block) else {
                throw EmbeddedToolchainProjectPublisherError.readBackFailed(EIO)
            }
            digest.update(data: block)
            total += count
        }
        var after = stat()
        var entry = stat()
        let entryStatus = name.withCString { fstatat(directory, $0, &entry, AT_SYMLINK_NOFOLLOW) }
        guard total == expected.count, fstat(descriptor, &after) == 0, entryStatus == 0,
              after.st_mode & S_IFMT == S_IFREG, entry.st_mode & S_IFMT == S_IFREG,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              entry.st_dev == after.st_dev, entry.st_ino == after.st_ino,
              after.st_size == before.st_size, entry.st_size == after.st_size,
              after.st_nlink > 0,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw EmbeddedToolchainProjectPublisherError.readBackFailed(EIO)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { throw EmbeddedToolchainProjectPublisherError.writeFailed(errno) }
            offset += count
        }
    }

    private static func openCanonicalDirectory(_ root: URL) throws -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw EmbeddedToolchainProjectPublisherError.invalidRoot("open filesystem root (errno \(errno))") }
        for component in root.path.split(separator: "/") {
            let next = String(component).withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            let failureCode = errno
            close(descriptor)
            guard next >= 0 else {
                throw EmbeddedToolchainProjectPublisherError.invalidRoot("open ancestor \(component) (errno \(failureCode))")
            }
            descriptor = next
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            close(descriptor); throw EmbeddedToolchainProjectPublisherError.invalidRoot("descriptor is not a directory")
        }
        return descriptor
    }

    private static func sameDirectoryIdentity(_ lhs: Int32, _ rhs: Int32) -> Bool {
        var left = stat()
        var right = stat()
        guard fstat(lhs, &left) == 0, fstat(rhs, &right) == 0 else { return false }
        return left.st_mode & S_IFMT == S_IFDIR && right.st_mode & S_IFMT == S_IFDIR &&
            left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    private static func directoryEntryMatches(_ parent: Int32, name: String, descriptor: Int32) -> Bool {
        var entry = stat()
        guard name.withCString({ fstatat(parent, $0, &entry, AT_SYMLINK_NOFOLLOW) }) == 0 else { return false }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { return false }
        return entry.st_mode & S_IFMT == S_IFDIR && opened.st_mode & S_IFMT == S_IFDIR &&
            entry.st_dev == opened.st_dev && entry.st_ino == opened.st_ino
    }

    private static func openOrCreateDirectory(_ name: String, under parent: Int32) throws -> Int32 {
        let created = name.withCString { mkdirat(parent, $0, mode_t(0o700)) }
        if created != 0 && errno != EEXIST {
            throw EmbeddedToolchainProjectPublisherError.directoryCreateFailed(errno)
        }
        let descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw EmbeddedToolchainProjectPublisherError.directoryCreateFailed(errno)
        }
        return descriptor
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isSafeRoot(_ root: URL) -> Bool {
        let parts = root.path.split(separator: "/").map(String.init)
        let forbidden = Set(["system", "usr", "bin", "sbin", "etc", "jb", "preboot"])
        return !parts.isEmpty && !parts.contains { component in
            let lowered = component.lowercased()
            return forbidden.contains(lowered) || lowered.hasSuffix(".app") || lowered.hasSuffix(".framework")
        }
    }

    private static func safeDylibFilename(_ name: String) -> Bool {
        guard let range = name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\\.dylib$", options: .regularExpression) else { return false }
        return range == (name.startIndex..<name.endIndex)
    }

    private static func safeDebFilename(_ name: String) -> Bool {
        guard let range = name.range(of: "^[A-Za-z0-9][A-Za-z0-9+._~-]{1,254}\\.deb$", options: .regularExpression) else { return false }
        return range == (name.startIndex..<name.endIndex)
    }

    private static func safeOutputFilename(_ name: String) -> Bool {
        safeDylibFilename(name) || safeDebFilename(name)
    }
}
