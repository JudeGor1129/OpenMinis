//
//  ContainerLocator.swift
//  MinisApp
//
//  Resolves the app's OWN data container explicitly, instead of asking
//  FileManager for `.documentDirectory` / `.libraryDirectory`.
//
//  [T-container-path-drift] Why this exists.
//
//  `platform-application` + `com.apple.private.security.no-sandbox` were added
//  to Minis.entitlements (run 74) so the app can posix_spawn the on-device
//  Theos toolchain — clang lives outside the app bundle, and a sandboxed
//  process cannot exec it. Those two entitlements are worth having.
//
//  Their side effect is that they change what the app's "home directory" means.
//  A sandboxed app's `.documentDirectory` is guaranteed to be
//  `<data-container>/Documents`; once the process is unsandboxed, the system
//  no longer has to honour that mapping, and on this device it stopped
//  honouring it. Observed on 2026-10-20: run 70 (no entitlements) wrote the
//  container 2AE68285-2177-4C6C-8BF7-DDF697A37911 and kept 17 sessions there;
//  run 74 came up with an empty session list, a storage page reading 0 bytes,
//  and a rootfs error, while that container still held every file untouched.
//
//  So we stop asking and start resolving. The container UUID is discoverable:
//  MobileContainerManager stamps every data container with a metadata plist
//  naming the bundle it belongs to. Reading it requires
//  `platform-application`, which we have — the same entitlement that broke the
//  implicit mapping also grants the means to rebuild it explicitly.
//
//  Everything here degrades to the previous behaviour if resolution fails. A
//  wrong-but-writable directory is worse than the old FileManager answer, so
//  the fallback chain ends at exactly the old code path.

import Foundation

enum ContainerLocator {
    /// Must not use AppLogger here: AppLogger reaches CrashReporter, whose
    /// paths depend on ContainerLocator and would recurse during static init.
    private static func log(_ message: String) { NSLog("[ContainerLocator] %@", message) }

    /// Root under which MobileContainerManager keeps per-app data containers.
    private static let dataContainersRoot = "/var/mobile/Containers/Data/Application"

    /// Resolved once. Container identity does not change within a process
    /// lifetime, and the scan touches ~290 directories, so it must not run on
    /// every `ChatStore` query.
    private static let resolved: URL? = resolve()

    /// The app's data container, or nil when it could not be resolved.
    static var dataContainer: URL? { resolved }

    /// `<container>/Documents`, or the FileManager answer when unresolved.
    static var documentsDirectory: URL {
        if let c = resolved {
            return c.appendingPathComponent("Documents", isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// `<container>/Library`, or the FileManager answer when unresolved.
    static var libraryDirectory: URL {
        if let c = resolved {
            return c.appendingPathComponent("Library", isDirectory: true)
        }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    }

    static var applicationSupportDirectory: URL {
        libraryDirectory.appendingPathComponent("Application Support", isDirectory: true)
    }

    static var cachesDirectory: URL {
        libraryDirectory.appendingPathComponent("Caches", isDirectory: true)
    }

    static var temporaryDirectory: URL {
        if let c = resolved { return c.appendingPathComponent("tmp", isDirectory: true) }
        return FileManager.default.temporaryDirectory
    }

    // MARK: - Resolution

    private static func resolve() -> URL? {
        let fm = FileManager.default
        guard let bundleID = Bundle.main.bundleIdentifier else {
            log("[Container] no bundle identifier; using FileManager paths")
            return nil
        }

        // A sandboxed process cannot enumerate container roots, so this whole
        // branch is a no-op without the entitlements. That is fine: without
        // them the FileManager answer is already correct.
        guard let names = try? fm.contentsOfDirectory(atPath: dataContainersRoot) else {
            log("[Container] \(dataContainersRoot) not enumerable — sandboxed, FileManager paths are authoritative")
            return nil
        }

        var candidates: [(created: Date, url: URL, hasStore: Bool, writable: Bool)] = []
        for name in names {
            let dir = URL(fileURLWithPath: dataContainersRoot, isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            let meta = dir.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard let data = try? Data(contentsOf: meta),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  (plist["MCMMetadataIdentifier"] as? String) == bundleID
            else { continue }

            // The store is the discriminator that matters. Two containers for one
            // bundle ID happens after a reinstall (the old one is orphaned), and
            // picking the empty one silently discards the user's history.
            let hasStore = fm.fileExists(
                atPath: dir.appendingPathComponent("Library/MinisChat/minis.db").path
            )
            let created = (try? fm.attributesOfItem(atPath: dir.path))?[.creationDate] as? Date ?? .distantPast
            candidates.append((created, dir, hasStore, isWritable(dir)))
        }

        guard !candidates.isEmpty else {
            log("[Container] no container matched \(bundleID); using FileManager paths")
            return nil
        }

        // Preference order: holds the real store > writable > newest. A container
        // with minis.db that is not writable is still better than a fresh empty
        // one — it at least fails visibly instead of looking like data loss.
        let ranked = candidates.sorted { a, b in
            if a.hasStore != b.hasStore { return a.hasStore }
            if a.writable != b.writable { return a.writable }
            return a.created > b.created
        }

        let pick = ranked[0]
        if candidates.count > 1 {
            log(
                "[Container] \(candidates.count) containers for \(bundleID); chose "
                + "\(pick.url.lastPathComponent) (store=\(pick.hasStore) writable=\(pick.writable))"
            )
        } else {
            log("[Container] resolved \(pick.url.lastPathComponent) (store=\(pick.hasStore))")
        }

        if !pick.writable {
            log("[Container] \(pick.url.lastPathComponent) is not writable; writes will fail")
        }
        return pick.url
    }

    /// True when a probe file can be created AND removed here.
    ///
    /// Stat is not enough: an unsandboxed process can see mode 0755 and still be
    /// refused by the sandbox profile when it actually creates a file.
    private static func isWritable(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let probe = dir.appendingPathComponent(".minis-container-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .atomic)
            try? fm.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }
}
