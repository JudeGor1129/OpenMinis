import Foundation

@main struct PerfPreserveContract {
    static func require(_ ok: Bool, _ label: String) {
        if !ok { fatalError("FAIL: \(label)") }
    }
    static func tool(name: String = "read", description: String = "读取文件", key: String = "path",
                     type: AgentParamType = .string, detail: String = "路径", values: [String]? = nil,
                     required: [String] = ["path"], order: [String]? = nil) -> AgentToolDefinition {
        AgentToolDefinition(name: name, description: description,
                            parameters: [key: AgentToolParam(type: type, description: detail, enumValues: values)],
                            required: required, propertyOrdering: order)
    }
    @MainActor static func main() async {
        var checks = 0
        var cache = FixedContextTokenCache()
        let original = tool()
        func verify(_ prompt: String, _ tools: [AgentToolDefinition]) {
            let expected = ContextSizeMeter.estimateFixedTokens(systemPrompt: prompt, tools: tools)
            require(cache.measure(systemPrompt: prompt, tools: tools) == expected, "exact estimate")
            checks += 1
        }
        verify("", []); verify("", []); require(cache.recomputations == 1, "empty hit")
        verify("保留全部信息", [original]); verify("保留全部信息", [original])
        require(cache.recomputations == 2, "repeat hit")
        let changes = [tool(name: "other"), tool(description: "新说明"), tool(key: "new"),
                       tool(type: .integer), tool(detail: "新参数说明"), tool(values: []),
                       tool(values: ["a", "b"]), tool(values: ["b", "a"]),
                       tool(required: []), tool(required: ["path", "x"]), tool(order: []), tool(order: ["path"])]
        for t in changes {
            verify("same", [original]); let n = cache.recomputations
            verify("same", [t]); require(cache.recomputations == n + 1, "all tool fields invalidate")
        }
        verify("same", [original, tool(name: "b")]); let n = cache.recomputations
        verify("same", [tool(name: "b"), original]); require(cache.recomputations == n + 1, "tool order")
        let composed = "\u{00e9}", decomposed = "e\u{0301}"
        require(composed == decomposed, "Unicode test canonical equality")
        verify(composed, []); let u = cache.recomputations
        verify(decomposed, []); require(cache.recomputations == u + 1, "UTF8 prompt invalidation")
        verify("p", [tool(key: composed)]); let k = cache.recomputations
        verify("p", [tool(key: decomposed)]); require(cache.recomputations == k + 1, "UTF8 dictionary key")
        for value in 0..<1000 {
            let prompt = String(repeating: "中文 e\u{0301} 🙂 Swift[] 123\n", count: value % 40) + String(value)
            verify(prompt, [tool(description: prompt, values: [String(value), "枚举"]), original])
            verify(prompt, [tool(description: prompt, values: [String(value), "枚举"]), original])
        }
        var fresh = FixedContextTokenCache()
        _ = fresh.measure(systemPrompt: "new run", tools: [])
        require(fresh.recomputations == 1, "run-local independent")

        for scale in [1.0, 2.0, 3.0] {
            for width in 1...2048 {
                let plan = BrowserSnapshotPolicy.plan(width: Double(width), scale: scale)!
                require(plan.pixelWidth % 32 == 0, "128-byte packed row")
                require(plan.snapshotWidth >= Double(width), "never downsample")
                require(plan.snapshotWidth * scale < Double(width) * scale + 32.000001, "bounded upward overhead")
                require(abs(plan.snapshotWidth / plan.widthRatio - Double(width)) < 1e-8, "CSS width preserved")
                checks += 4
            }
        }
        for bad in [0.0, -1, Double.nan, Double.infinity, Double.greatestFiniteMagnitude] {
            require(BrowserSnapshotPolicy.plan(width: bad, scale: 3) == nil, "invalid width")
            require(BrowserSnapshotPolicy.plan(width: 390, scale: bad) == nil, "invalid scale")
        }
        var bucket = PerfProbe.PipelineBucket()
        for seconds in [0.0, 0.01, 0.03, -1, Double.nan, Double.infinity] { bucket.record(seconds: seconds) }
        require(bucket.count == 3 && abs(bucket.sum - 0.04) < 1e-9 && bucket.maximum == 0.03, "aggregate")
        require(bucket.metrics.contains("avg_ms=13.333") && bucket.metrics.contains("max_ms=30.000"), "metrics")
        AppLogger.reset()
        PerfProbe.recordPipeline(.toolQueue, since: 2, until: 1)
        PerfProbe.flush(); require(AppLogger.lines.isEmpty, "invalid monotonic span ignored")
        DispatchQueue.concurrentPerform(iterations: 2000) { _ in
            PerfProbe.recordPipeline(.toolQueue, since: 1_000_000, until: 3_000_000)
        }
        PerfProbe.flush()
        require(AppLogger.lines.count == 1 && AppLogger.lines[0].contains("n=2000 avg_ms=2.000 max_ms=2.000"), "concurrent recording")
        AppLogger.reset(); PerfProbe.flush(); require(AppLogger.lines.isEmpty, "flush reset, idle silent")
        require(PerfProbe.PipelinePhase.allCases.count == 12, "bounded cardinality")
        let value = await PerfProbe.measureRequestOpen { 42 }
        require(value == 42, "request return preserved")
        enum Expected: Error { case failure }
        let failed: Int? = try? await PerfProbe.measureRequestOpen { throw Expected.failure }
        require(failed == nil, "request error preserved")
        PerfProbe.flush()
        require(AppLogger.lines.count == 1 && AppLogger.lines[0].contains("phase=request_open n=2"), "failed and successful requests recorded")
        AppLogger.reset()
        for pair in [(393.0, 3.0), (430.0, 2.0)] {
            let plan = BrowserSnapshotPolicy.plan(width: pair.0, scale: pair.1)!
            require(Int((Double(plan.pixelWidth) / (pair.1 * plan.widthRatio)).rounded()) == Int(pair.0), "fractional UIImage scale does not truncate CSS metadata")
        }
        print("PASS: production source cache, raster policy, concurrent timers; \(checks) assertions")

        let prompt = String(repeating: "Preserve every capability 中文安全验证 1234\n", count: 8000)
        let tools = (0..<80).map { tool(name: "tool\($0)", description: String(repeating: "description 工具说明 ", count: 140)) }
        var fast = FixedContextTokenCache(); let expected = fast.measure(systemPrompt: prompt, tools: tools)
        var totals = 0, base: [Double] = [], memo: [Double] = []
        for _ in 0..<5 {
            var start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<60 { totals += ContextSizeMeter.estimateFixedTokens(systemPrompt: prompt, tools: tools) }
            base.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<60 { totals += fast.measure(systemPrompt: prompt, tools: tools) }
            memo.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        require(totals == expected * 600, "benchmark exact output")
        let b = base.sorted()[2], m = memo.sorted()[2]
        print(String(format: "BENCH fixed-estimate 60 iterations median: baseline=%.3fms memo=%.3fms ratio=%.4f", b, m, m / b))
        require(m < b, "cache must actually beat baseline on unchanged large input")
    }
}
