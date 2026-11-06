import Foundation
import SwiftUI

/// One iPhoneOS SDK the native compiler can use.
struct ToolchainSDK: Identifiable, Equatable, Sendable {
    let version: String
    let path: URL
    let sizeBytes: Int64
    /// True when the SDK lives in the app-owned library (survives a rootfs
    /// reset). False for the copy inside the iSH rootfs, which is only listed
    /// so it can be imported; the native compiler never reads it directly.
    let isAppOwned: Bool

    var id: String { version }
    var displayName: String { "iPhoneOS \(version)" }
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// App-owned iPhoneOS SDK library: scan, import (ZIP or iSH copy), download,
/// select and delete.
///
/// This is a *file library*, not a compiler: nothing here executes a build or
/// shells out. It writes only inside the app container, which is exactly what
/// `OMToolchain` reads (`Library/Application Support/MinisToolchain/SDKs`
/// plus the `toolchain.selectedSDKVersion` preference).
@MainActor
final class ToolchainSDKLibrary: ObservableObject {
    static let shared = ToolchainSDKLibrary()

    enum Phase: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    @Published private(set) var sdks: [ToolchainSDK] = []
    @Published private(set) var phase: Phase = .idle
    @Published var notice: String?

    /// Same key OMToolchain reads when it picks a sysroot.
    static let selectedVersionKey = "toolchain.selectedSDKVersion"

    private init() {}

    // MARK: - Locations

    nonisolated static var appOwnedDirectory: URL {
        ContainerLocator.applicationSupportDirectory
            .appendingPathComponent("MinisToolchain/SDKs", isDirectory: true)
    }

    /// Guest SDK directory inside the Alpine rootfs, as a host path.
    nonisolated static var rootfsSDKDirectory: URL {
        ContainerLocator.documentsDirectory
            .appendingPathComponent("alpine-rootfs/data/opt/theos/sdks", isDirectory: true)
    }

    // MARK: - Selection

    var selectedVersion: String? {
        UserDefaults.standard.string(forKey: Self.selectedVersionKey)
    }

    var selectedSDK: ToolchainSDK? {
        if let version = selectedVersion, let match = sdks.first(where: { $0.version == version }) {
            return match
        }
        return sdks.first
    }

    func select(_ sdk: ToolchainSDK) {
        UserDefaults.standard.set(sdk.version, forKey: Self.selectedVersionKey)
        notice = "构建将使用 \(sdk.displayName)"
    }

    // MARK: - Scan

    func refresh() {
        let appDir = Self.appOwnedDirectory
        let rootDir = Self.rootfsSDKDirectory
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                Self.scan(appOwned: appDir, rootfs: rootDir)
            }.value
            self.sdks = found
            if self.selectedSDK == nil, let first = found.first {
                UserDefaults.standard.set(first.version, forKey: Self.selectedVersionKey)
            }
        }
    }

    nonisolated static func scan(appOwned: URL, rootfs: URL) -> [ToolchainSDK] {
        var byVersion: [String: ToolchainSDK] = [:]
        for (directory, owned) in [(appOwned, true), (rootfs, false)] {
            for sdk in sdkDirectories(in: directory) {
                let version = versionOf(sdk)
                guard !version.isEmpty else { continue }
                // App-owned wins: same version can exist in both places.
                if let existing = byVersion[version], existing.isAppOwned { continue }
                byVersion[version] = ToolchainSDK(
                    version: version,
                    path: sdk,
                    sizeBytes: directorySize(sdk),
                    isAppOwned: owned)
            }
        }
        return byVersion.values.sorted {
            $0.version.compare($1.version, options: .numeric) == .orderedDescending
        }
    }

    nonisolated static func sdkDirectories(in directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.filter {
            $0.lastPathComponent.hasPrefix("iPhoneOS") && $0.pathExtension == "sdk"
        }
    }

    nonisolated static func versionOf(_ sdk: URL) -> String {
        var name = sdk.lastPathComponent
        if name.hasPrefix("iPhoneOS") { name.removeFirst("iPhoneOS".count) }
        if name.hasSuffix(".sdk") { name.removeLast(".sdk".count) }
        return name
    }

    /// Usable = real headers and a non-placeholder libSystem stub. Mirrors
    /// OMToolchain's own acceptance test so the list never offers an SDK the
    /// linker would reject.
    nonisolated static func isUsable(_ sdk: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sdk.appendingPathComponent("usr/include").path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        let stub = sdk.appendingPathComponent("usr/lib/libSystem.B.tbd")
        let size = (try? fm.attributesOfItem(atPath: stub.path)[.size] as? NSNumber)?.intValue ?? 0
        return size >= 1024
    }

    nonisolated static func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return 0 }
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    // MARK: - Install

    /// Import a local ZIP: extract, locate `iPhoneOS*.sdk`, validate, install.
    func install(zipURL: URL) {
        guard phase == .idle || isFailed else { return }
        phase = .working("正在解包 SDK…")
        notice = nil
        Task {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("sdk-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try BackupZipExtractor.extract(zipURL, to: staging)
                    Self.materializePlaceholderSymlinks(in: staging)
                }.value
                guard let found = Self.locateSDK(in: staging) else {
                    throw SDKLibraryError.noSDKInArchive
                }
                let version = try await Task.detached(priority: .userInitiated) {
                    try Self.install(sdkAt: found)
                }.value
                UserDefaults.standard.set(version, forKey: Self.selectedVersionKey)
                phase = .idle
                notice = "已安装 iPhoneOS \(version)"
                refresh()
            } catch {
                phase = .failed(Self.describe(error))
            }
        }
    }

    /// Download a ZIP from a URL and install it. Only the user supplies the
    /// URL — no endpoint is baked into the app.
    func download(from url: URL) {
        guard phase == .idle || isFailed else { return }
        guard url.scheme == "http" || url.scheme == "https" else {
            phase = .failed("请填写 http(s) 下载链接")
            return
        }
        phase = .working("正在下载 SDK…")
        notice = nil
        Task {
            do {
                let (temporary, response) = try await URLSession.shared.download(from: url)
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    throw SDKLibraryError.httpStatus(http.statusCode)
                }
                let zip = FileManager.default.temporaryDirectory
                    .appendingPathComponent("sdk-download-\(UUID().uuidString).zip")
                try? FileManager.default.removeItem(at: zip)
                try FileManager.default.moveItem(at: temporary, to: zip)
                phase = .idle
                install(zipURL: zip)
            } catch {
                phase = .failed(Self.describe(error))
            }
        }
    }

    nonisolated static func locateSDK(in root: URL) -> URL? {
        let fm = FileManager.default
        if root.pathExtension == "sdk", isUsable(root) { return root }
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        if let direct = entries.first(where: { $0.pathExtension == "sdk" && isUsable($0) }) {
            return direct
        }
        // One nested level (ZIPs made by "compress folder" usually wrap it).
        for directory in entries where (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let children = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            if let nested = children.first(where: { $0.pathExtension == "sdk" && isUsable($0) }) {
                return nested
            }
        }
        return nil
    }

    /// Move a validated SDK into the app-owned library and return its version.
    nonisolated static func install(sdkAt source: URL) throws -> String {
        guard isUsable(source) else { throw SDKLibraryError.unusableSDK(source.lastPathComponent) }
        let fm = FileManager.default
        let version = versionOf(source)
        guard !version.isEmpty else { throw SDKLibraryError.unusableSDK(source.lastPathComponent) }
        let store = appOwnedDirectory
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        let destination = store.appendingPathComponent("iPhoneOS\(version).sdk", isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: source, to: destination)
        return version
    }

    func remove(_ sdk: ToolchainSDK) {
        guard sdk.isAppOwned else {
            notice = "rootfs 里的 SDK 请到 iSH 中删除，App 不会修改 Alpine 系统文件"
            return
        }
        do {
            try FileManager.default.removeItem(at: sdk.path)
            if selectedVersion == sdk.version {
                UserDefaults.standard.removeObject(forKey: Self.selectedVersionKey)
            }
            notice = "已删除 \(sdk.displayName)"
            refresh()
        } catch {
            phase = .failed("删除失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return error.localizedDescription
    }

    /// ZIP stores a symlink as a tiny file whose *content* is the link target.
    /// Extracting it naively leaves text files where the SDK needs links
    /// (`libSystem.tbd` and 71 others), which the linker then rejects. Recreate
    /// them as real symlinks; the same heuristic the iSH importer uses.
    nonisolated static func materializePlaceholderSymlinks(in root: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) else { return }
        // Collect first, mutate after: removing entries while an enumerator is
        // walking the same tree leaves the enumerator in an undefined state.
        var links: [(URL, String)] = []
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size < 512,
                  let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty, !target.hasPrefix("/"),
                  !target.contains(" "), !target.contains("\n"),
                  !target.contains("<"), !target.contains("#") else { continue }
            let resolved = file.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
            guard fm.fileExists(atPath: resolved.path) else { continue }
            links.append((file, target))
        }
        for (file, target) in links {
            try? fm.removeItem(at: file)
            try? fm.createSymbolicLink(atPath: file.path, withDestinationPath: target)
        }
    }
}

enum SDKLibraryError: LocalizedError {
    case noSDKInArchive
    case unusableSDK(String)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .noSDKInArchive:
            return "ZIP 里没有找到可用的 iPhoneOS*.sdk"
        case .unusableSDK(let name):
            return "\(name) 不完整：缺少 usr/include 或 libSystem.tbd 不是真实库桩"
        case .httpStatus(let code):
            return "下载失败：HTTP \(code)"
        }
    }
}
