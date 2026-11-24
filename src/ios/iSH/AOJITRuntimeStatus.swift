// Official 1.15 jit_describe report parser, separated from SwiftUI.
import Foundation

/// Per-module line of the runtime's report: images accepted / rejected and
/// blocks / AOT hits / of which moved (see jit_describe in deps/ish).
struct AOJITRuntimeStatus {
    struct Coverage: Equatable {
        var blocks = 0
        /// Blocks installed from an image.
        var hits = 0
        /// Of those, found by content in another version (family matching).
        var moved = 0
    }
    var rejected: Set<String> = []
    var accepted: Set<String> = []
    var hits: [String: Coverage] = [:]
    var abi: String?

    /// Totals over every module file the image serves: the recorded file and
    /// any other version in its family (reported under its own real path).
    func coverage(for image: AOJITImage) -> Coverage? {
        let rows = hits.filter { $0.key == image.recordedPath || image.servesFamily(($0.key as NSString).lastPathComponent) }
        guard !rows.isEmpty else { return nil }
        return rows.values.reduce(into: Coverage()) { $0.blocks += $1.blocks; $0.hits += $1.hits; $0.moved += $1.moved }
    }

    init(report: String) {
        for raw in report.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let r = line.range(of: "(abi ") {
                abi = String(line[r.upperBound...].prefix { $0 != ")" })
            }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if parts.count >= 2, parts[0] == "ok" { accepted.insert(parts[1]) }
            if parts.count >= 2, parts[0].hasPrefix("rejected") { rejected.insert(parts[1]) }
            // "/path   blocks / hits / moved" (moved: family runtimes; absent before)
            if parts.count >= 4, parts[0].hasPrefix("/"), parts[2] == "/",
               let blocks = Int(parts[1]), let hit = Int(parts[3]) {
                let moved = parts.count >= 6 && parts[4] == "/" ? Int(parts[5]) ?? 0 : 0
                hits[parts[0]] = Coverage(blocks: blocks, hits: hit, moved: moved)
            }
        }
    }
}
