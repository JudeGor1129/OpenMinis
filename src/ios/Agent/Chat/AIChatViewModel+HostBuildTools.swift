//
//  AIChatViewModel+HostBuildTools.swift
//  MinisApp
//
//  On-device Theos build driver.  [T-host-build-tweak]
//
//  WHY THIS NEEDS A SPECIAL ENTITLEMENT
//  ------------------------------------
//  Compiling a jailbreak tweak on the device requires executing a compiler
//  binary that lives outside this app's container (/var/jb/usr/bin/clang).
//  A sandboxed app cannot do that: posix_spawn of a foreign executable is
//  denied by the sandbox regardless of file permissions. Twork solves this
//  with `platform-application` + `com.apple.private.security.no-sandbox`,
//  and this port now declares the same two entitlements in
//  src/ios/Minis.entitlements. They are only honoured because the IPA is
//  installed through TrollStore, which re-signs with an authority that will
//  grant them.
//
//  This file therefore does two things:
//    1. probe whether a usable toolchain is actually installed, and
//    2. drive `make` in a Theos project and report the artifact.
//
//  It deliberately does NOT silently pretend to build. If the toolchain is
//  absent it says so and names the packages to install, because the single
//  most common failure here is a missing compiler, and a vague "build failed"
//  sends the reader hunting for a source-code bug that does not exist.
//

import Foundation

extension AIChatViewModel {

    // MARK: - Toolchain discovery

    /// Directories that may hold the Theos runtime, most specific first.
    ///
    /// Twork keeps its runtime in its own container rather than /var/theos,
    /// so both are probed. A stub directory that exists but has no
    /// `makefiles/` is NOT a usable runtime, which is why presence alone is
    /// never treated as success.
    nonisolated static func hostTheosCandidateRoots() -> [String] {
        var roots: [String] = []
        // Explicit override wins, so a user with a custom install can point at it.
        if let env = ProcessInfo.processInfo.environment["THEOS"], !env.isEmpty {
            roots.append(env)
        }
        roots.append(contentsOf: [
            "/var/theos",
            "/var/jb/opt/theos",
            "/var/jb/usr/share/theos",
            "/opt/theos",
        ])
        // Twork's runtime, addressed through its container.
        roots.append(NSHomeDirectory() + "/../Library/Application Support/TworkRuntime/theos")
        return roots
    }

    /// A resolved on-device build environment.
    struct HostToolchain {
        let theos: String
        let make: String
        let clang: String
        let sdk: String?
    }

    /// First path in `candidates` at which `predicate` holds.
    nonisolated static func hostFirstMatch(_ candidates: [String],
                                           _ predicate: (String) -> Bool) -> String? {
        for c in candidates where predicate(c) { return c }
        return nil
    }

    nonisolated static func hostIsDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    nonisolated static func hostIsExecutableFile(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// Resolve the toolchain, or return the reason it is unusable.
    nonisolated static func hostResolveToolchain() -> (toolchain: HostToolchain?, report: [String]) {
        var report: [String] = []

        // make: Twork ships one in its own bundle, Procursus ships another.
        let makeCandidates = [
            "/var/jb/usr/bin/make",
            "/var/jb/bin/make",
            "/usr/bin/make",
            "/private/var/containers/Bundle/Application/20050636-A0DB-47BC-AC2D-8684A6F806C4/Twork.app/bin/make",
        ]
        let make = hostFirstMatch(makeCandidates, hostIsExecutableFile)

        // clang: the Procursus LLVM package installs it here.
        let clangCandidates = [
            "/var/jb/usr/bin/clang",
            "/var/jb/usr/lib/llvm-16/bin/clang",
            "/var/jb/usr/lib/llvm-14/bin/clang",
        ]
        let clang = hostFirstMatch(clangCandidates, hostIsExecutableFile)

        // Theos: must contain makefiles/common.mk, not merely exist.
        let theos = hostFirstMatch(hostTheosCandidateRoots()) { root in
            FileManager.default.fileExists(atPath: root + "/makefiles/common.mk")
        }

        // SDK: prefer the highest version present.
        var sdk: String?
        for root in ([theos].compactMap { $0 } + hostTheosCandidateRoots()) {
            let sdksDir = root + "/sdks"
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: sdksDir) else { continue }
            let sdkNames = names.filter { $0.hasPrefix("iPhoneOS") && $0.hasSuffix(".sdk") }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            if let best = sdkNames.first {
                sdk = sdksDir + "/" + best
                break
            }
        }

        report.append("make:    " + (make ?? "NOT FOUND"))
        report.append("clang:   " + (clang ?? "NOT FOUND"))
        report.append("theos:   " + (theos ?? "NOT FOUND (no makefiles/common.mk)"))
        report.append("sdk:     " + (sdk ?? "NOT FOUND"))

        guard let make, let clang, let theos else {
            report.append("")
            report.append("The on-device toolchain is incomplete, so no build can run.")
            report.append("Install it from the Procursus repository (Sileo), then retry:")
            report.append("    clang  llvm-16  llvm-16-dev  ld64  odcctools  ldid  make  libtapi")
            report.append("That chain provides the compiler, the Mach-O linker and the signer.")
            report.append("Note: the SDK's .tbd stubs must also be present under")
            report.append("    <theos>/sdks/iPhoneOS*.sdk/usr/lib")
            return (nil, report)
        }

        if sdk == nil {
            report.append("")
            report.append("WARNING: no iPhoneOS SDK was found under <theos>/sdks.")
            report.append("Theos cannot link without it, even though clang exists.")
            return (nil, report)
        }

        return (HostToolchain(theos: theos, make: make, clang: clang, sdk: sdk), report)
    }

    // MARK: - Project validation

    /// A Theos project is identified by its packaging metadata plus a target
    /// definition. A directory with a Makefile but no `control` produces no
    /// .deb, and saying so up front is more useful than a make error.
    nonisolated static func hostValidateTheosProject(_ dir: String) -> [String] {
        var problems: [String] = []
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return ["Not a directory: \(dir)"]
        }
        if !fm.fileExists(atPath: dir + "/Makefile") { problems.append("missing Makefile") }
        if !fm.fileExists(atPath: dir + "/control") { problems.append("missing control (no .deb metadata)") }
        // A tweak needs Logos source; an application needs a main source file.
        let entries = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        let hasSource = entries.contains { name in
            let lower = name.lowercased()
            return lower.hasSuffix(".x") || lower.hasSuffix(".xm")
                || lower.hasSuffix(".m") || lower.hasSuffix(".mm") || lower.hasSuffix(".swift")
        }
        if !hasSource { problems.append("no source file (.x/.xm/.m/.mm/.swift) found") }
        // Theos writes intermediates here; an absent dir is normal, a file is not.
        var tmpIsDir: ObjCBool = false
        if fm.fileExists(atPath: dir + "/.theos", isDirectory: &tmpIsDir), !tmpIsDir.boolValue {
            problems.append(".theos exists but is a file, not a directory")
        }
        return problems
    }

    // MARK: - Process execution

    /// Collected output from a child process. A class (not a tuple) so the two
    /// pipe readers can write without capturing and mutating a local variable
    /// from two different queues.
    final class HostProcessOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var _stdout = Data()
        private var _stderr = Data()
        func appendStdout(_ d: Data) { lock.lock(); _stdout.append(d); lock.unlock() }
        func appendStderr(_ d: Data) { lock.lock(); _stderr.append(d); lock.unlock() }
        var stdout: Data { lock.lock(); defer { lock.unlock() }; return _stdout }
        var stderr: Data { lock.lock(); defer { lock.unlock() }; return _stderr }
    }

    struct HostProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
        let launchError: String?
    }

    /// Run `executable` to completion, capturing both streams.
    ///
    /// The pipes are drained on background queues: reading only after
    /// `waitUntilExit()` deadlocks as soon as the child writes more than the
    /// pipe buffer (64 KB), and a compiler easily does.
    nonisolated static func hostRunProcess(executable: String,
                                           arguments: [String],
                                           workingDirectory: String,
                                           environment: [String: String],
                                           timeout: TimeInterval) -> HostProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Never let the child block on stdin waiting for input.
        process.standardInput = FileHandle.nullDevice

        let collected = HostProcessOutput()
        do {
            try process.run()
        } catch {
            return HostProcessResult(status: -1, stdout: "", stderr: "",
                                     timedOut: false,
                                     launchError: error.localizedDescription)
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            if let d = try? outPipe.fileHandleForReading.readToEnd() { collected.appendStdout(d ?? Data()) }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            if let d = try? errPipe.fileHandleForReading.readToEnd() { collected.appendStderr(d ?? Data()) }
            group.leave()
        }

        // Poll rather than waitUntilExit(): a hung build must not hang the agent.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            // Give it a moment to die, then move on. `interrupt` is not
            // enough for a compiler that has spawned subprocesses.
            Thread.sleep(forTimeInterval: 1.0)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        _ = group.wait(timeout: .now() + 5)
        process.waitUntilExit()

        return HostProcessResult(status: process.terminationStatus,
                                 stdout: String(data: collected.stdout, encoding: .utf8) ?? "",
                                 stderr: String(data: collected.stderr, encoding: .utf8) ?? "",
                                 timedOut: timedOut,
                                 launchError: nil)
    }

    // MARK: - Build

    /// Cap on how much build output is echoed. A failing Swift build can emit
    /// megabytes; the caller only needs enough to act.
    nonisolated static let hostBuildOutputLimit = 12_000
    nonisolated static let hostBuildDefaultTimeout: TimeInterval = 900

    nonisolated static func hostTail(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return "…(truncated, showing last \(limit) characters)\n" + String(text.suffix(limit))
    }

    func executeHostBuildTweak(from json: String) async -> FileToolResult {
        guard let dict = Self.hostArgs(json) else {
            return FileToolResult(output: "Error: arguments were not a JSON object.", success: false)
        }
        let rawPath = (dict["path"] as? String) ?? ""
        let root = (dict["root"] as? String) ?? "ios"
        let packageMode = Self.hostBool(dict["package"]) ?? true
        let clean = Self.hostBool(dict["clean"]) ?? false
        var timeout = Self.hostBuildDefaultTimeout
        if let t = Self.hostInt(dict["timeout"]), t > 0 { timeout = TimeInterval(min(t, 3600)) }

        let resolution = resolveHostToolPath(rawPath, root: root)
        if let error = resolution.error {
            return FileToolResult(output: "Error: \(error)", success: false)
        }
        guard let projectDir = resolution.url?.path, !projectDir.isEmpty else {
            return FileToolResult(output: "Error: could not resolve project path.", success: false)
        }

        var lines: [String] = []
        lines.append("project: \(projectDir)")

        let problems = Self.hostValidateTheosProject(projectDir)
        if !problems.isEmpty {
            lines.append("")
            lines.append("This directory is not a buildable Theos project:")
            lines.append(contentsOf: problems.map { "  - " + $0 })
            return FileToolResult(output: lines.joined(separator: "\n"), success: false)
        }

        let (toolchainOpt, toolchainReport) = Self.hostResolveToolchain()
        guard let toolchain = toolchainOpt else {
            lines.append("")
            lines.append(contentsOf: toolchainReport)
            return FileToolResult(output: lines.joined(separator: "\n"), success: false)
        }
        lines.append(contentsOf: toolchainReport)
        lines.append("")

        // Environment for Theos. PATH must lead with the Procursus bin dir so
        // `make` finds clang/ld64 rather than the (absent) system ones, and
        // THEOS must be absolute because Theos derives $THEOS_MAKE_PATH from it.
        var env = ProcessInfo.processInfo.environment
        env["THEOS"] = toolchain.theos
        env["PATH"] = "/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let sdk = toolchain.sdk {
            env["SDKVERSION"] = ((sdk as NSString).lastPathComponent as NSString)
                .replacingOccurrences(of: "iPhoneOS", with: "")
                .replacingOccurrences(of: ".sdk", with: "")
        }
        env["TWORK_DEPLOYMENT_VERSION"] = "14.0"
        // Keep the user's locale out of the compiler's diagnostics parsing.
        env["LC_ALL"] = "C"

        if clean {
            let cleanResult = Self.hostRunProcess(executable: toolchain.make,
                                                  arguments: ["clean"],
                                                  workingDirectory: projectDir,
                                                  environment: env,
                                                  timeout: 120)
            lines.append("make clean: exit \(cleanResult.status)")
        }

        let makeArgs = packageMode ? ["package", "FINALPACKAGE=1"] : []
        lines.append("running: make " + makeArgs.joined(separator: " "))
        let result = Self.hostRunProcess(executable: toolchain.make,
                                         arguments: makeArgs,
                                         workingDirectory: projectDir,
                                         environment: env,
                                         timeout: timeout)

        if let launchError = result.launchError {
            lines.append("")
            lines.append("Could not start make: \(launchError)")
            lines.append("If this is a permissions error, the app was launched from a")
            lines.append("signature that did not grant platform-application / no-sandbox.")
            return FileToolResult(output: lines.joined(separator: "\n"), success: false)
        }

        lines.append("exit status: \(result.status)" + (result.timedOut ? " (TIMED OUT)" : ""))
        let combined = result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)
        if !combined.isEmpty {
            lines.append("")
            lines.append(Self.hostTail(combined, limit: Self.hostBuildOutputLimit))
        }

        // Report the artifact rather than a bare exit code: "make exited 0" is
        // not evidence that a .deb exists, and vice versa.
        lines.append("")
        let packagesDir = projectDir + "/packages"
        var artifacts: [String] = []
        if let names = try? FileManager.default.contentsOfDirectory(atPath: packagesDir) {
            artifacts = names.filter { $0.hasSuffix(".deb") || $0.hasSuffix(".ipa") }
                .sorted()
                .map { packagesDir + "/" + $0 }
        }
        if artifacts.isEmpty {
            lines.append("No .deb/.ipa was produced in packages/.")
            if result.status == 0 {
                lines.append("make reported success but produced no package — inspect the output above.")
            }
        } else {
            lines.append("artifact(s):")
            for a in artifacts {
                let attrs = try? FileManager.default.attributesOfItem(atPath: a)
                let size = (attrs?[.size] as? NSNumber)?.intValue
                let human = size.map { Self.hostByteSize($0) } ?? "size unknown"
                lines.append("  \(a)  (\(human))")
            }
        }

        let success = result.status == 0 && !result.timedOut && !artifacts.isEmpty
        return FileToolResult(output: lines.joined(separator: "\n"), success: success)
    }
}
