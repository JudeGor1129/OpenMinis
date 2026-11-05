import Foundation

struct EmbeddedUniversalSlice: Codable, Equatable, Sendable {
    let architecture: String
    let cpuSubtype: UInt32
    let offset: Int
    let bytes: Int
    let sha256: String
}

struct EmbeddedUniversalArtifact: Codable, Equatable, Sendable {
    let name: String
    let bytes: Int
    let sha256: String
    /// MH_DYLIB (6) for a SpringBoard tweak, MH_EXECUTE (2) for a daemon.
    let filetype: UInt32
    let slices: [EmbeddedUniversalSlice]
    var architectures: [String] { slices.map(\.architecture) }
}

/// Bounded Mach-O file types this FAT writer can carry. Objects (MH_OBJECT) are
/// deliberately absent: a universal container is only ever produced from a real
/// linked dylib or executable.
enum EmbeddedUniversalFileType: UInt32, Sendable {
    case executable = 2
    case dylib = 6

    var kind: String { self == .dylib ? "dylib" : "executable" }
}

struct EmbeddedUniversalExecutionResult: Sendable {
    let reports: [EmbeddedAdapterResult]
    let artifact: EmbeddedUniversalArtifact?
    /// Ephemeral capability: not Codable and never reconstructed from reports.
    let data: Data?
    let reason: String
    var passed: Bool {
        reports.count == 2 && reports.allSatisfy(\.passed) && artifact != nil && data != nil
    }
}

/// Canonical FAT32 writer/reader for precisely arm64 + arm64e dylibs.
/// It operates on owned, already-inspected bytes, never on external paths.
/// Every slice header is preserved, so changing a name/header cannot fake arm64e.
enum EmbeddedToolchainUniversalBinary {
    static let alignment = 16 * 1024
    static let maxBytes = 32 * 1024 * 1024 + 3 * alignment

    private static func rejected(_ message: String) -> EmbeddedAdapterError {
        .rejected("universal dylib rejected: " + message)
    }
    static func read32(_ data: Data, at offset: Int, bigEndian: Bool = true) -> UInt32 {
        let shifts = bigEndian ? [24, 16, 8, 0] : [0, 8, 16, 24]
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(data[offset + index]) << shifts[index] }
        return value
    }
    private static func append32(_ value: UInt32, to data: inout Data) {
        for shift in [24, 16, 8, 0] { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    private static func align(_ offset: Int) -> Int {
        (offset + alignment - 1) & ~(alignment - 1)
    }

    static func merge(arm64: Data, arm64e: Data, name: String,
                      filetype: UInt32 = EmbeddedUniversalFileType.dylib.rawValue,
                      cancellation: EmbeddedAdapterCancellation = EmbeddedAdapterCancellation()) throws -> Data {
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard [EmbeddedUniversalFileType.executable.rawValue,
               EmbeddedUniversalFileType.dylib.rawValue].contains(filetype) else {
            throw rejected("unsupported container file type")
        }
        let slices = [arm64, arm64e]
        let targets: [EmbeddedToolchainArchitecture] = [.arm64, .arm64e]
        for index in 0..<2 {
            _ = try EmbeddedAdapterArtifact.inspect(slices[index], name: name, filetype: filetype,
                                                    architecture: targets[index])
        }
        let offsets = [align(48), align(align(48) + arm64.count)]
        let total = offsets[1] + arm64e.count
        guard total <= maxBytes else { throw rejected("total byte budget") }
        var data = Data()
        data.reserveCapacity(total)
        append32(0xcafebabe, to: &data); append32(2, to: &data)
        for index in 0..<2 {
            append32(0x0100000c, to: &data)
            append32(read32(slices[index], at: 8, bigEndian: false), to: &data)
            append32(UInt32(offsets[index]), to: &data)
            append32(UInt32(slices[index].count), to: &data)
            append32(14, to: &data)
        }
        for index in 0..<2 {
            guard !cancellation.isCancelled else { throw CancellationError() }
            data.append(Data(repeating: 0, count: offsets[index] - data.count))
            data.append(slices[index])
        }
        _ = try inspect(data, name: name, filetype: filetype)
        guard !cancellation.isCancelled else { throw CancellationError() }
        return data
    }

    static func inspect(_ data: Data, name: String,
                        filetype: UInt32 = EmbeddedUniversalFileType.dylib.rawValue) throws -> EmbeddedUniversalArtifact {
        guard data.count >= 48, data.count <= maxBytes,
              read32(data, at: 0) == 0xcafebabe, read32(data, at: 4) == 2 else {
            throw rejected("requires canonical FAT32 with exactly two slices")
        }
        let targets: [EmbeddedToolchainArchitecture] = [.arm64, .arm64e]
        var cursor = 48
        var metadata: [EmbeddedUniversalSlice] = []
        for index in 0..<2 {
            let record = 8 + index * 20
            let subtype = read32(data, at: record + 4)
            let offset = Int(read32(data, at: record + 8))
            let bytes = Int(read32(data, at: record + 12))
            let expectedOffset = align(cursor)
            guard read32(data, at: record) == 0x0100000c,
                  targets[index].accepts(subtype: subtype),
                  read32(data, at: record + 16) == 14, offset == expectedOffset,
                  bytes >= 32, bytes <= 16 * 1024 * 1024,
                  offset <= data.count, bytes <= data.count - offset else {
                throw rejected("architecture/table/range/alignment mismatch at slice \(index)")
            }
            guard data[cursor..<offset].allSatisfy({ $0 == 0 }) else {
                throw rejected("nonzero bytes in container padding")
            }
            let thin = Data(data[offset..<(offset + bytes)])
            let artifact = try EmbeddedAdapterArtifact.inspect(thin, name: name, filetype: filetype,
                                                              architecture: targets[index])
            guard read32(thin, at: 8, bigEndian: false) == subtype else {
                throw rejected("FAT table differs from thin slice header")
            }
            metadata.append(EmbeddedUniversalSlice(architecture: artifact.architecture, cpuSubtype: subtype,
                                                   offset: offset, bytes: bytes, sha256: artifact.sha256))
            cursor = offset + bytes
        }
        guard cursor == data.count else { throw rejected("trailing bytes/hidden slice") }
        return EmbeddedUniversalArtifact(name: name, bytes: data.count,
            sha256: EmbeddedAdapterArtifact.digest(data), filetype: filetype, slices: metadata)
    }
}
