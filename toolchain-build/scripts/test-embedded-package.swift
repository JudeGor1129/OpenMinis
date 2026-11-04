import Foundation

private struct PackageContractFailure: Error, CustomStringConvertible {
    let description: String
}

/// Actual production FAT/DEB modules plus the same injectable adapter seam.
/// Patched headers below are ONLY synthetic fixture construction, never a
/// compiler implementation or evidence that native arm64e compilation works.
@MainActor
enum PackageContracts {
    static func run(outputDirectory: String) async throws -> Int {
        var checks = 0
        func require(_ condition: Bool, _ message: String) throws {
            checks += 1
            if !condition { throw PackageContractFailure(description: message) }
        }
        func rejects(_ message: String, _ body: () throws -> Void) throws {
            do { try body() }
            catch is EmbeddedAdapterError { checks += 1; return }
            catch is CancellationError { checks += 1; return }
            throw PackageContractFailure(description: "accepted invalid package case: " + message)
        }
        func patchBE(_ data: inout Data, _ offset: Int, _ value: UInt32) {
            let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
            data.replaceSubrange(offset..<(offset + 4), with: bytes)
        }
        let m = EmbeddedDebMetadata(packageID: "com.minis.contract", name: "Minis contract",
            version: "1.0", maintainer: "Contract tests", description: "Synthetic validation fixture, not installable evidence",
            tweakName: "ContractTweak", bundleIDs: ["com.minis.contracttarget"])
        let arm64 = MachOFixture.image(filetype: 6, installName: "@rpath/" + m.dylibName, includesObjC: true)
        var arm64e = arm64
        MachOFixture.patch(&arm64e, 8, 0x80000002)
        _ = try EmbeddedAdapterArtifact.inspect(arm64e, name: m.dylibName, filetype: 6, architecture: .arm64e)
        checks += 1
        try rejects("arm64e silently downgraded") {
            _ = try EmbeddedAdapterArtifact.inspect(arm64, name: m.dylibName, filetype: 6, architecture: .arm64e)
        }
        try rejects("arm64 assigned arm64e") {
            _ = try EmbeddedAdapterArtifact.inspect(arm64e, name: m.dylibName, filetype: 6)
        }
        let fat = try EmbeddedToolchainUniversalBinary.merge(arm64: arm64, arm64e: arm64e, name: m.dylibName)
        let info = try EmbeddedToolchainUniversalBinary.inspect(fat, name: m.dylibName)
        try require(info.architectures == ["arm64", "arm64e"], "precisely the two requested target slices")
        try require(info.slices.map(\.cpuSubtype) == [0, 0x80000002], "per-slice ABI subtypes preserved")
        try require(info.slices.map(\.sha256) == [EmbeddedAdapterArtifact.digest(arm64), EmbeddedAdapterArtifact.digest(arm64e)], "thin bytes never rewritten by merge")
        for (slice, bytes) in zip(info.slices, [arm64, arm64e]) {
            try require(Data(fat[slice.offset..<(slice.offset + slice.bytes)]) == bytes, "slice bytes survive merge exactly")
            try require(slice.offset % 16384 == 0, "slice page alignment")
        }
        let mutations: [(Int, UInt32)] = [
            (0, 0xcafebabf), (0, 0xfeedfacf), (4, 0), (4, 1), (4, 3),
            (8, 0x01000007), (12, 2), (16, 32), (16, 16385), (20, 0), (24, 31),
            (28, 0x01000007), (32, 0), (32, 0x81000002),
            (36, UInt32(info.slices[0].offset)), (36, .max), (40, .max), (44, 13)
        ]
        for (offset, value) in mutations {
            var invalid = fat; patchBE(&invalid, offset, value)
            try rejects("fat header mutation at \(offset)") { _ = try EmbeddedToolchainUniversalBinary.inspect(invalid, name: m.dylibName) }
        }
        var badPadding = fat; badPadding[48] = 1
        try rejects("nonzero FAT padding") { _ = try EmbeddedToolchainUniversalBinary.inspect(badPadding, name: m.dylibName) }
        var appended = fat; appended.append(0)
        try rejects("hidden trailing bytes") { _ = try EmbeddedToolchainUniversalBinary.inspect(appended, name: m.dylibName) }
        for count in [0, 7, 47, fat.count - 1] {
            try rejects("truncated FAT") { _ = try EmbeddedToolchainUniversalBinary.inspect(Data(fat.prefix(count)), name: m.dylibName) }
        }
        var mismatched = fat
        MachOFixture.patch(&mismatched, info.slices[1].offset + 8, 2)
        try rejects("table and slice ABI differ") { _ = try EmbeddedToolchainUniversalBinary.inspect(mismatched, name: m.dylibName) }
        var encrypted = arm64e
        MachOFixture.patch(&encrypted, MachOFixture.commandOffset(0x2c, in: encrypted) + 16, 1)
        try rejects("encrypted target cannot merge") {
            _ = try EmbeddedToolchainUniversalBinary.merge(arm64: arm64, arm64e: encrypted, name: m.dylibName)
        }
        try rejects("two copies of arm64 cannot fake dual") {
            _ = try EmbeddedToolchainUniversalBinary.merge(arm64: arm64, arm64e: arm64, name: m.dylibName)
        }
        let token = EmbeddedAdapterCancellation(); token.cancel()
        try rejects("cancelled merge") {
            _ = try EmbeddedToolchainUniversalBinary.merge(arm64: arm64, arm64e: arm64e, name: m.dylibName, cancellation: token)
        }

        let deb = try EmbeddedToolchainDebPackage.build(dylib: fat, metadata: m)
        let debInfo = try EmbeddedToolchainDebPackage.inspect(deb, metadata: m)
        try require(debInfo.universal == info && debInfo.sha256 == EmbeddedAdapterArtifact.digest(deb), "DEB roundtrip binds slices and archive hash")
        try require(debInfo.payloadPath == m.payloadDirectory + "/" + m.dylibName, "rootless tweak payload path")
        try require(debInfo.filename == "com.minis.contract_1.0_iphoneos-arm64.deb", "Debian bootstrap arch is not the slice list")
        try require(try EmbeddedToolchainDebPackage.build(dylib: fat, metadata: m) == deb, "deterministic DEB creation")
        try rejects("cancelled package") { _ = try EmbeddedToolchainDebPackage.build(dylib: fat, metadata: m, cancellation: token) }
        try rejects("thin dylib cannot become requested DEB") { _ = try EmbeddedToolchainDebPackage.build(dylib: arm64, metadata: m) }
        for count in [0, 7, 67, deb.count - 1] {
            try rejects("truncated DEB") { _ = try EmbeddedToolchainDebPackage.inspect(Data(deb.prefix(count)), metadata: m) }
        }
        var badMagic = deb; badMagic[0] = 0
        try rejects("invalid ar magic") { _ = try EmbeddedToolchainDebPackage.inspect(badMagic, metadata: m) }
        var badArSize = deb; badArSize[56] = 120
        try rejects("invalid ar size") { _ = try EmbeddedToolchainDebPackage.inspect(badArSize, metadata: m) }
        var badVersion = deb; badVersion[68] = 51
        try rejects("DEB version mismatch") { _ = try EmbeddedToolchainDebPackage.inspect(badVersion, metadata: m) }
        var badChecksum = deb; badChecksum[132] ^= 1
        try rejects("tar checksum invalid") { _ = try EmbeddedToolchainDebPackage.inspect(badChecksum, metadata: m) }
        if let body = deb.range(of: m.control) {
            var alteredControl = deb; alteredControl[body.lowerBound] ^= 1
            try rejects("control content changed") { _ = try EmbeddedToolchainDebPackage.inspect(alteredControl, metadata: m) }
        } else { throw PackageContractFailure(description: "control content is missing from DEB") }
        let encodedMetadata = try JSONEncoder().encode(m)
        let jsonMetadata = try JSONSerialization.jsonObject(with: encodedMetadata) as! [String: Any]
        let invalidValues: [(String, Any)] = [
            ("packageID", "Bad.Package"), ("packageID", "x"), ("packageID", "../evil"),
            ("name", "Name\nDepends: injected"), ("maintainer", "a\r\nb"),
            ("description", "a\u{2028}b"), ("version", "x1"), ("version", "1 2"),
            ("tweakName", "../Tweak"), ("bundleIDs", [String]()),
            ("bundleIDs", ["com.x", "com.x"]), ("bundleIDs", ["*"])
        ]
        for (key, value) in invalidValues {
            var json = jsonMetadata; json[key] = value
            let metadata = try JSONDecoder().decode(EmbeddedDebMetadata.self,
                from: JSONSerialization.data(withJSONObject: json))
            try rejects("metadata field \(key)") { try metadata.validate() }
        }

        let input = ["answer.m": "int answer(void) { return 42; }\n"]
        let ops: [EmbeddedToolchainOperation] = [
            .compile(source: "answer.m", output: "answer.o", language: .objectiveC),
            .link(objects: ["answer.o"], output: m.dylibName, installName: "@rpath/" + m.dylibName)
        ]
        let fake = FakeBridge()
        let adapter = EmbeddedToolchainExecutionAdapter(bridge: fake)
        let execution = await adapter.executeUniversal(sources: input, operations: ops)
        try require(execution.passed && execution.artifact?.architectures == ["arm64", "arm64e"], "dual execution captures only completed FAT")
        try require(execution.reports.map(\.processLinkCount) == [1, 2] && fake.snapshot().kinds == ["compile", "link", "compile", "link"], "two independent serial target runs")
        let calls = fake.snapshot().calls
        try require(calls.count == 4 && calls[0].contains("arm64-apple-ios15.0") && calls[2].contains("arm64e-apple-ios15.0"), "CC1 triples bound to each target")
        try require(calls[0].contains("apple-a7") && calls[2].contains("apple-a12") && calls[2].contains("-fptrauth-returns"), "arm64e CPU/return authentication flags")
        try require(calls[1].contains("arm64") && calls[3].contains("arm64e") && fake.snapshot().objcStubs == 2, "ld64 targets and two ObjC stub copies")
        try require(execution.reports.allSatisfy {
            !$0.providerExecutable && !$0.outputExecutionAttempted && $0.temporaryOutputsRemoved && $0.capturedDylibData == nil
        }, "completed reports expose no separate thin binary capability")
        try require(fake.snapshot().roots.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "both private run directories removed")
        let secondBuild = await adapter.executeUniversal(sources: input, operations: ops)
        try require(!secondBuild.passed && secondBuild.data == nil && fake.snapshot().calls.count == 4,
                    "insufficient two-link admission makes zero new bridge calls")

        for bad in [Outcome.diagnostics, .downgraded, .malformed] {
            let failedFake = FakeBridge(link: [.ok, bad])
            let failed = await EmbeddedToolchainExecutionAdapter(bridge: failedFake)
                .executeUniversal(sources: input, operations: ops)
            try require(!failed.passed && failed.data == nil && failed.artifact == nil, "second target failure cannot publish partial FAT")
            try require(failed.reports.allSatisfy { $0.capturedDylibData == nil && $0.artifacts.isEmpty }, "no first-target capability after failure")
            try require(failedFake.snapshot().roots.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "second target failure cleans both directories")
        }
        let preFake = FakeBridge()
        let preCancelled = await EmbeddedToolchainExecutionAdapter(bridge: preFake)
            .executeUniversal(sources: input, operations: ops, cancellation: token)
        try require(!preCancelled.passed && preFake.snapshot().calls.isEmpty, "pre-cancel reaches no bridge calls")
        let lateToken = EmbeddedAdapterCancellation()
        let lateFake = FakeBridge(cancelAtSample: (11, lateToken))
        let lateCancelled = await EmbeddedToolchainExecutionAdapter(bridge: lateFake)
            .executeUniversal(sources: input, operations: ops, cancellation: lateToken)
        try require(!lateCancelled.passed && lateCancelled.data == nil && lateCancelled.reports.allSatisfy { $0.capturedDylibData == nil },
                    "cancel at post-merge RSS sample clears export capability")
        let concurrentFake = FakeBridge()
        let concurrentAdapter = EmbeddedToolchainExecutionAdapter(bridge: concurrentFake)
        async let one = concurrentAdapter.executeUniversal(sources: input, operations: ops)
        async let two = concurrentAdapter.executeUniversal(sources: input, operations: ops)
        let (first, second) = await (one, two)
        try require([first, second].filter(\.passed).count == 1 && concurrentFake.snapshot().calls.count == 4,
                    "native queue cannot interleave dual builds or overspend link admission")

        // Export synthetic contract fixtures ONLY for independent archive/lipo
        // readers in CI. This is not a usable, signed plugin or native evidence.
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try fat.write(to: directory.appendingPathComponent("contract-fat.dylib"))
        try deb.write(to: directory.appendingPathComponent("contract.deb"))
        try JSONEncoder().encode(m).write(to: directory.appendingPathComponent("contract-metadata.json"))
        try JSONEncoder().encode(debInfo).write(to: directory.appendingPathComponent("contract-evidence.json"))
        print("PASS: \(checks) architecture, dual-transaction, FAT and DEB contracts (synthetic fixtures, no native LLVM/output execution)")
        return checks
    }
}
