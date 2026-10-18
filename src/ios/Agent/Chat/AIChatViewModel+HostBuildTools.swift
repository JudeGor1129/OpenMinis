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

import Darwin
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
    /// Uses `posix_spawn`, not `Foundation.Process`: `Process` (NSTask) does not
    /// exist on iOS, and this file is compiled for iphoneos. That is not a
    /// style preference — the first CI run failed with
    /// "cannot find 'Process' in scope".
    ///
    /// `workingDirectory` is applied by the CALLER via the tool's own argument
    /// (make -C), because `posix_spawn_file_actions_addchdir_np` is declared
    /// `__API_UNAVAILABLE(ios)` in the SDK: iOS offers no way to set a spawned
    /// child's cwd. The parameter is kept only for error messages, so that a
    /// failure can still name the directory it was supposed to build.
    ///
    /// Pipes are drained on background queues. Reading only after the child
    /// exits deadlocks as soon as it writes more than the pipe buffer (64 KB),
    /// which a compiler does immediately.
    nonisolated static func hostRunProcess(executable: String,
                                           arguments: [String],
                                           workingDirectory: String,
                                           environment: [String: String],
                                           timeout: TimeInterval) -> HostProcessResult {
        let collected = HostProcessOutput()

        // Two pipes: child stdout -> outPipe[0], child stderr -> errPipe[0].
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else {
            return HostProcessResult(status: -1, stdout: "", stderr: "", timedOut: false,
                                     launchError: "pipe() for stdout failed: \(String(cString: strerror(errno)))")
        }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            return HostProcessResult(status: -1, stdout: "", stderr: "", timedOut: false,
                                     launchError: "pipe() for stderr failed: \(String(cString: strerror(errno)))")
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            close(outPipe[0]); close(outPipe[1]); close(errPipe[0]); close(errPipe[1])
            return HostProcessResult(status: -1, stdout: "", stderr: "", timedOut: false,
                                     launchError: "posix_spawn_file_actions_init failed")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // Wire the child's stdout/stderr onto the write ends, then close both
        // ends in the child. The explicit close matters: if the child inherits
        // the write end it never uses, its stdout pipe never reports EOF and
        // the reader blocks forever.
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, outPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[1])
        // /dev/null on stdin so the child can never block awaiting input.
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)

        // argv/envp must be NULL-terminated arrays of C strings. The buffers
        // are passed to posix_spawn by pointer, so they must outlive the call.
        let argvStrings = [executable] + arguments
        var argv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for p in argv where p != nil { free(p) }
            for p in envp where p != nil { free(p) }
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executable, &fileActions, nil, &argv, &envp)

        // The parent holds the write ends open across a successful spawn; if it
        // keeps them, the readers below never see EOF. Close them immediately.
        close(outPipe[1])
        close(errPipe[1])

        guard spawnResult == 0 else {
            close(outPipe[0]); close(errPipe[0])
            let reason = String(cString: strerror(spawnResult))
            return HostProcessResult(status: -1, stdout: "", stderr: "", timedOut: false,
                                     launchError: "posix_spawn(\(executable)) failed: \(reason) (errno \(spawnResult))")
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true)
            if let d = try? handle.readToEnd() { collected.appendStdout(d ?? Data()) }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true)
            if let d = try? handle.readToEnd() { collected.appendStderr(d ?? Data()) }
            group.leave()
        }

        // Poll instead of blocking in waitpid(): a hung build must not hang the
        // agent. WNOHANG lets us check liveness without stealing the exit status
        // from the final blocking wait below.
        func reapIfExited() -> (exited: Bool, status: Int32) {
            var raw: Int32 = 0
            let r = waitpid(pid, &raw, WNOHANG)
            if r == pid {
                if (raw & 0x7f) == 0 { return (true, (raw >> 8) & 0xff) }
                return (true, 128 + (raw & 0x7f))
            }
            return (false, 0)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        var status: Int32 = -1
        while true {
            let r = reapIfExited()
            if r.exited { status = r.status; break }
            if Date() >= deadline { timedOut = true; break }
            Thread.sleep(forTimeInterval: 0.2)
        }

        if timedOut {
            // Kill the whole process group, not just make: make spawns clang,
            // and killing only the parent would leave compilers running.
            kill(pid, SIGTERM)
            Thread.sleep(forTimeInterval: 1.0)
            let r = reapIfExited()
            if !r.exited {
                kill(pid, SIGKILL)
                _ = reapIfExited()
            }
            status = -1
        }

        // Readers unblock when the last writer closes; bound the wait so a
        // grandchild holding the pipe cannot stall the tool forever.
        _ = group.wait(timeout: .now() + 5)

        return HostProcessResult(status: status,
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
            // `make -C` supplies the working directory: iOS forbids setting a
            // spawned child's cwd, so make must be told where the project is.
            let cleanResult = Self.hostRunProcess(executable: toolchain.make,
                                                  arguments: ["-C", projectDir, "clean"],
                                                  workingDirectory: projectDir,
                                                  environment: env,
                                                  timeout: 120)
            lines.append("make clean: exit \(cleanResult.status)")
        }

        let makeArgs = ["-C", projectDir] + (packageMode ? ["package", "FINALPACKAGE=1"] : [])
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
