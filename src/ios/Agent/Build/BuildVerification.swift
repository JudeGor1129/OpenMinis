import Foundation

// MARK: - Compiler diagnostics

enum BuildLogAnalyzer {
    private static let locationWithColumn = try! NSRegularExpression(
        pattern: #"^(.+?):([0-9]+):([0-9]+):\s*(fatal error|error|warning|note):\s*(.+)$"#,
        options: [.caseInsensitive]
    )
    private static let locationWithoutColumn = try! NSRegularExpression(
        pattern: #"^(.+?):([0-9]+):\s*(fatal error|error|warning|note):\s*(.+)$"#,
        options: [.caseInsensitive]
    )
    private static let globalDiagnostic = try! NSRegularExpression(
        pattern: #"^(?:([^:]+):\s*)?(fatal error|error|warning|note):\s*(.+)$"#,
        options: [.caseInsensitive]
    )
    private static let makeDiagnostic = try! NSRegularExpression(
        pattern: #"^(make(?:\[[0-9]+\])?:\s*\*\*\*.*(?:Error|Stop).*)$"#,
        options: [.caseInsensitive]
    )

    static func analyze(_ text: String, limit: Int = 1_000) -> BuildLogAnalysis {
        var diagnostics: [BuildDiagnostic] = []
        var seen = Set<BuildDiagnostic>()
        let lines = text.components(separatedBy: .newlines)
        for raw in lines {
            let line = stripBuildPrefix(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let diagnostic = parse(line), seen.insert(diagnostic).inserted else { continue }
            diagnostics.append(diagnostic)
            if diagnostics.count == limit { break }
        }
        let firstError = diagnostics.first { $0.severity == .error || $0.severity == .fatal }
        return BuildLogAnalysis(
            diagnostics: diagnostics,
            firstError: firstError,
            errorCount: diagnostics.filter { $0.severity == .error || $0.severity == .fatal }.count,
            warningCount: diagnostics.filter { $0.severity == .warning }.count,
            truncated: diagnostics.count == limit && lines.count > limit
        )
    }

    private static func parse(_ line: String) -> BuildDiagnostic? {
        if let groups = captures(locationWithColumn, in: line), groups.count == 5 {
            return BuildDiagnostic(
                file: normalizedFile(groups[0]),
                line: Int(groups[1]),
                column: Int(groups[2]),
                severity: severity(groups[3]),
                message: groups[4],
                tool: tool(for: groups[0], message: groups[4]),
                raw: line
            )
        }
        if let groups = captures(locationWithoutColumn, in: line), groups.count == 4 {
            return BuildDiagnostic(
                file: normalizedFile(groups[0]),
                line: Int(groups[1]),
                column: nil,
                severity: severity(groups[2]),
                message: groups[3],
                tool: tool(for: groups[0], message: groups[3]),
                raw: line
            )
        }
        if captures(makeDiagnostic, in: line) != nil {
            return BuildDiagnostic(file: nil, line: nil, column: nil, severity: .error, message: line, tool: "make", raw: line)
        }
        if let groups = captures(globalDiagnostic, in: line), groups.count == 3 {
            let prefix = groups[0].trimmingCharacters(in: .whitespaces)
            // Do not turn arbitrary prose containing a colon into a compiler diagnostic.
            let severityValue = severity(groups[1])
            guard severityValue != .note || prefix.isEmpty || prefix.contains("swift") || prefix.contains("clang") || prefix.contains("xcodebuild") else { return nil }
            return BuildDiagnostic(
                file: prefix.contains("/") || prefix.contains(".") ? normalizedFile(prefix) : nil,
                line: nil,
                column: nil,
                severity: severityValue,
                message: groups[2],
                tool: tool(for: prefix, message: groups[2]),
                raw: line
            )
        }
        if line.localizedCaseInsensitiveContains("command phasescriptexecution failed with a nonzero exit code") {
            return BuildDiagnostic(file: nil, line: nil, column: nil, severity: .error, message: line, tool: "xcodebuild", raw: line)
        }
        return nil
    }

    private static func captures(_ regex: NSRegularExpression, in value: String) -> [String]? {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return "" }
            return String(value[swiftRange])
        }
    }

    private static func severity(_ value: String) -> BuildDiagnosticSeverity {
        switch value.lowercased() {
        case "fatal error": return .fatal
        case "error": return .error
        case "warning": return .warning
        default: return .note
        }
    }

    private static func normalizedFile(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "<unknown>" ? nil : trimmed
    }

    private static func tool(for file: String, message: String) -> String {
        let lower = (file + " " + message).lowercased()
        if lower.contains(".swift") || lower.contains("swift") { return "swift" }
        if lower.contains("xcode") || lower.contains("codesign") || lower.contains("provision") { return "xcodebuild" }
        if lower.contains("clang") || lower.contains(".m ") || lower.contains(".mm ") || lower.contains(".c ") || lower.contains(".cpp ") { return "clang" }
        return "compiler"
    }

    private static func stripBuildPrefix(_ value: String) -> String {
        var line = value
        // xcodebuild often prefixes parallel output with timestamps/process labels.
        if let range = line.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}[^ ]*\s+"#, options: .regularExpression) {
            line.removeSubrange(range)
        }
        return line
    }
}

// MARK: - Real artifact verification

@MainActor
enum ArtifactVerifier {
    static func verify(path: String, requestedKind: ArtifactKind?, executor: BuildShellExecutor) async -> ArtifactVerificationResult {
        let kind = requestedKind ?? inferKind(path)
        let script = verificationScript(path: path, kind: kind)
        do {
            let result = try await executor(script, 120)
            return parse(output: result.output, path: path, kind: kind, wrapperExit: result.exitCode)
        } catch {
            return failure(path: path, kind: kind, message: error.localizedDescription)
        }
    }

    nonisolated static func inferKind(_ path: String) -> ArtifactKind {
        let lower = path.lowercased()
        if lower.hasSuffix(".ipa") { return .ipa }
        if lower.hasSuffix(".deb") { return .deb }
        if lower.hasSuffix(".dylib") || lower.hasSuffix(".framework") { return .macho }
        return .binary
    }

    private static func verificationScript(path: String, kind: ArtifactKind) -> String {
        let q = ShellEscaping.singleQuote(path)
        return """
        set +x
        artifact=\(q)
        kind=\(ShellEscaping.singleQuote(kind.rawValue))
        emit() { printf '%s=' "$1"; printf '%s' "$2" | base64 | tr -d '\\n'; printf '\\n'; }
        cap() { emit CAP "$1|$2|$3"; }
        if test ! -f "$artifact"; then emit EXISTS 0; emit ERROR 'Artifact does not exist or is not a regular file.'; exit 0; fi
        emit EXISTS 1
        size="$(stat -c %s "$artifact" 2>/dev/null || stat -f %z "$artifact" 2>/dev/null || true)"
        emit SIZE "$size"
        if command -v sha256sum >/dev/null 2>&1; then sha="$(sha256sum "$artifact" | awk '{print $1}')"; emit SHA256 "$sha"; cap sha256 verified sha256sum
        elif command -v shasum >/dev/null 2>&1; then sha="$(shasum -a 256 "$artifact" | awk '{print $1}')"; emit SHA256 "$sha"; cap sha256 verified shasum
        else cap sha256 unavailable 'sha256sum/shasum missing'; emit ERROR 'SHA-256 capability unavailable.'; fi
        tmp="${TMPDIR:-/tmp}/minis-artifact-$$"; rm -rf "$tmp"; mkdir -p "$tmp"
        list="$tmp/archive.list"; control="$tmp/control"; macho="$artifact"
        if test "$kind" = ipa; then
          macho=""
          if command -v unzip >/dev/null 2>&1 && unzip -tqq "$artifact" >/dev/null 2>&1 && unzip -Z1 "$artifact" >"$list" 2>/dev/null; then
            cap archive verified unzip
            count="$(wc -l <"$list" | tr -d ' ')"; emit ENTRY_COUNT "$count"
            head -500 "$list" | while IFS= read -r entry; do emit ENTRY "$entry"; done
            if ! grep -Eq '^Payload/[^/]+\\.app/' "$list"; then emit ERROR 'IPA is missing Payload/*.app layout.'; fi
            candidate_list="$tmp/ipa-candidates"
            awk -F/ '/^Payload\\// && $0 !~ /\\/$/ { base=$NF; if (base !~ /\\./ || base ~ /\\.dylib$/) print }' "$list" | head -100 >"$candidate_list"
            if command -v file >/dev/null 2>&1; then
              found=""
              while IFS= read -r entry; do
                unzip -p "$artifact" "$entry" >"$tmp/macho.bin" 2>/dev/null || continue
                info="$(file "$tmp/macho.bin" 2>/dev/null)"
                case "$info" in *Mach-O*|*universal*) found="$entry: ${info#*: }"; macho="$tmp/macho.bin"; break ;; esac
              done <"$candidate_list"
              if test -n "$found"; then emit FILE_INFO "$found"; cap architecture verified file; else cap architecture failed 'No Mach-O file found in first 100 executable candidates'; emit ERROR 'IPA contains no detectable Mach-O binary.'; fi
            else cap architecture unavailable 'file executable missing'; fi
          else cap archive failed 'unzip missing or archive unreadable'; emit ERROR 'IPA archive is unreadable.'; fi
        elif test "$kind" = deb; then
          macho=""
          if command -v dpkg-deb >/dev/null 2>&1 && dpkg-deb -c "$artifact" >"$tmp/deb.list.raw" 2>/dev/null; then
            cap archive verified dpkg-deb
            dpkg-deb -f "$artifact" >"$control" 2>/dev/null || true
            sed -E 's#^.* \\.?/#/#' "$tmp/deb.list.raw" >"$list"
          elif command -v ar >/dev/null 2>&1 && ar t "$artifact" >"$tmp/ar.list" 2>/dev/null; then
            member="$(grep '^control.tar' "$tmp/ar.list" | head -1)"; data_member="$(grep '^data.tar' "$tmp/ar.list" | head -1)"
            if test -n "$member" && test -n "$data_member" && ar p "$artifact" "$member" | tar -xO -f - ./control >"$control" 2>/dev/null && ar p "$artifact" "$data_member" | tar -tf - >"$list" 2>/dev/null; then cap archive verified ar+tar; else cap archive failed 'DEB control/data member unreadable'; emit ERROR 'DEB archive members are unreadable.'; fi
          else cap archive failed 'dpkg-deb/ar missing or archive unreadable'; emit ERROR 'DEB archive is unreadable.'; fi
          if test -s "$control"; then emit CONTROL "$(cat "$control")"; cap deb_control verified control; else cap deb_control failed 'control missing'; emit ERROR 'DEB control metadata is missing.'; fi
          if test -s "$list"; then
            count="$(wc -l <"$list" | tr -d ' ')"; emit ENTRY_COUNT "$count"; head -500 "$list" | while IFS= read -r entry; do emit ENTRY "$entry"; done
            violations="$(sed -E 's#^\\./##; s#^/##' "$list" | grep -Ev '^var/?$|^var/jb(/|$)|^$' | head -100 || true)"
            if test -z "$violations"; then emit ROOTLESS true; cap rootless verified 'all payload paths under /var/jb'; else emit ROOTLESS false; printf '%s\\n' "$violations" | while IFS= read -r entry; do emit ROOTLESS_VIOLATION "$entry"; done; cap rootless failed 'payload contains paths outside /var/jb'; fi
          fi
        else
          cap archive not_applicable 'plain binary'
          if command -v file >/dev/null 2>&1; then info="$(file "$artifact" 2>/dev/null)"; emit FILE_INFO "$info"; case "$info" in *Mach-O*|*universal*) cap architecture verified file ;; *) cap architecture unavailable 'not identified as Mach-O' ;; esac
          else cap architecture unavailable 'file executable missing'; fi
        fi
        if test -n "$macho" && test -f "$macho" && command -v otool >/dev/null 2>&1; then
          if otool -hv "$macho" >"$tmp/otool.header" 2>/dev/null; then
            arch="$(tail -n +2 "$tmp/otool.header" | awk '{print $2}' | sort -u | tr '\\n' ' ')"; emit OTOOL_ARCH "$arch"
            if otool -l "$macho" >"$tmp/otool.load" 2>/dev/null; then crypt="$(awk '/LC_ENCRYPTION_INFO/{seen=1} seen && /cryptid/{print $2; exit}' "$tmp/otool.load")"; if test -n "$crypt"; then emit ENCRYPTION "cryptid $crypt"; else emit ENCRYPTION 'no LC_ENCRYPTION_INFO load command'; fi; cap encryption verified otool; else cap encryption failed 'otool load commands failed'; fi
          else cap encryption failed 'otool did not recognize selected binary'; fi
        else cap encryption unavailable 'otool unavailable or no Mach-O selected'; fi
        if test -n "$macho" && test -f "$macho" && command -v codesign >/dev/null 2>&1; then
          if sig="$(codesign -dv --verbose=2 "$macho" 2>&1)"; then emit SIGNATURE "$(printf '%s' "$sig" | head -20)"; cap signature verified codesign; else emit SIGNATURE "$(printf '%s' "$sig" | head -20)"; cap signature failed 'codesign reports unsigned or invalid'; fi
        elif test -n "$macho" && test -f "$macho" && command -v ldid >/dev/null 2>&1; then
          if sig="$(ldid -e "$macho" 2>&1)"; then emit SIGNATURE "$(printf '%s' "$sig" | head -20)"; cap signature verified ldid; else cap signature failed 'ldid could not read signature'; fi
        else cap signature unavailable 'codesign/ldid unavailable or no Mach-O selected'; fi
        rm -rf "$tmp"
        exit 0
        """
    }

    private static func parse(output: String, path: String, kind: ArtifactKind, wrapperExit: Int) -> ArtifactVerificationResult {
        var exists = false
        var size: Int64?
        var sha: String?
        var entries: [String] = []
        var entryCount = 0
        var fileInfo: [String] = []
        var otoolArch: [String] = []
        var encryption: String?
        var signature: String?
        var controlText = ""
        var rootless: Bool?
        var violations: [String] = []
        var capabilities: [VerificationCapability] = []
        var errors: [String] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equal])
            let encoded = String(line[line.index(after: equal)...])
            guard let data = Data(base64Encoded: encoded), let value = String(data: data, encoding: .utf8) else { continue }
            switch key {
            case "EXISTS": exists = value == "1"
            case "SIZE": size = Int64(value)
            case "SHA256": sha = value
            case "ENTRY": entries.append(value)
            case "ENTRY_COUNT": entryCount = Int(value) ?? entries.count
            case "FILE_INFO": fileInfo.append(value)
            case "OTOOL_ARCH": otoolArch.append(value)
            case "ENCRYPTION": encryption = value
            case "SIGNATURE": signature = value
            case "CONTROL": controlText = value
            case "ROOTLESS": rootless = value == "true"
            case "ROOTLESS_VIOLATION": violations.append(value)
            case "ERROR": errors.append(value)
            case "CAP":
                let fields = value.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                if fields.count == 3 {
                    capabilities.append(.init(name: fields[0], state: VerificationCapabilityState(rawValue: fields[1]) ?? .unavailable, detail: fields[2]))
                }
            default: break
            }
        }
        if wrapperExit != 0 { errors.append("Verification wrapper exited \(wrapperExit).") }
        if exists && (size ?? 0) <= 0 { errors.append("Artifact is empty.") }
        if exists && sha == nil { errors.append("SHA-256 was not produced.") }
        let control = parseControl(controlText)
        if kind == .deb && control["Package"] == nil { errors.append("DEB control has no Package field.") }
        let architectures = parseArchitectures(fileInfo: fileInfo, otool: otoolArch, control: control)
        let state: ArtifactState
        if !exists { state = .missing }
        else if errors.isEmpty { state = .available }
        else { state = .invalid }
        return ArtifactVerificationResult(
            path: path,
            kind: kind,
            state: state,
            exists: exists,
            sizeBytes: size,
            sha256: sha,
            archiveEntries: entries,
            archiveEntryCount: max(entryCount, entries.count),
            architectures: architectures,
            encryption: encryption,
            signature: signature,
            debControl: control,
            rootlessPaths: rootless,
            rootlessViolations: violations,
            capabilities: capabilities,
            errors: errors
        )
    }

    private static func parseControl(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var activeKey: String?
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix(" "), let activeKey {
                result[activeKey, default: ""] += "\n" + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon])
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                result[key] = value
                activeKey = key
            }
        }
        return result
    }

    private static func parseArchitectures(fileInfo: [String], otool: [String], control: [String: String]) -> [String] {
        let known = ["arm64e", "arm64", "aarch64", "x86_64", "i386", "armv7", "armv7s"]
        let combined = (fileInfo + otool + [control["Architecture"] ?? ""]).joined(separator: " ").lowercased()
        var result = known.filter { combined.contains($0) }
        if result.contains("arm64") && result.contains("arm64e"), let index = result.firstIndex(of: "arm64") { result.remove(at: index) }
        return result
    }

    private static func failure(path: String, kind: ArtifactKind, message: String) -> ArtifactVerificationResult {
        ArtifactVerificationResult(path: path, kind: kind, state: .invalid, exists: false, sizeBytes: nil, sha256: nil, archiveEntries: [], archiveEntryCount: 0, architectures: [], encryption: nil, signature: nil, debControl: [:], rootlessPaths: nil, rootlessViolations: [], capabilities: [], errors: [message])
    }
}
