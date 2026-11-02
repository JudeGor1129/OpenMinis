import Foundation
import SwiftUI
import UIKit

struct EmbeddedAdapterValidationOutcome: Codable, Sendable {
    let name: String
    let expectedState: String
    let result: EmbeddedAdapterResult
    var passed: Bool { result.state == expectedState && result.temporaryOutputsRemoved }
}

struct EmbeddedAdapterValidationReport: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case schema, suite, providerExecutable, outputExecutionAttempted, outputFilesPublished
        case outcomes, cancelled, passed
    }
    let schema = 1
    let suite = "restricted_operation_adapter_validation"
    let providerExecutable = false
    let outputExecutionAttempted = false
    let outputFilesPublished = false
    var outcomes: [EmbeddedAdapterValidationOutcome] = []
    var cancelled = false
    var passed = false

    static func run(cancellation: EmbeddedAdapterCancellation) async -> Self {
        let adapter = EmbeddedToolchainExecutionAdapter.shared
        var report = Self()
        let alreadyCancelled = EmbeddedAdapterCancellation()
        alreadyCancelled.cancel()
        let preCancelled = await adapter.execute(sources: ["probe.c": "int probe(void) { return 1; }"],
            operations: [.compile(source: "probe.c", output: "probe.o", language: .c)], cancellation: alreadyCancelled)
        report.outcomes.append(.init(name: "cancel_before_compile", expectedState: "cancelled", result: preCancelled))
        guard !cancellation.isCancelled else { report.cancelled = true; return report }
        let success = await adapter.execute(sources: [
            "probe.c": "extern int objc_probe(void); int probe(void) { return objc_probe() + 1; }",
            "objc.m": "@interface AdapterProbe @end\nint objc_probe(void) { return 7; }"
        ], operations: [
            .compile(source: "probe.c", output: "probe.o", language: .c),
            .compile(source: "objc.m", output: "objc.o", language: .objectiveC),
            .link(objects: ["probe.o", "objc.o"], output: "probe.dylib", installName: "@rpath/probe.dylib")
        ], cancellation: cancellation)
        report.outcomes.append(.init(name: "compile_link_inspect_cleanup", expectedState: "success", result: success))
        guard success.passed, !cancellation.isCancelled else { report.cancelled = cancellation.isCancelled; return report }
        let badCompile = await adapter.execute(sources: ["broken.c": "int broken( { return 0; }"],
            operations: [.compile(source: "broken.c", output: "broken.o", language: .c)], cancellation: cancellation)
        report.outcomes.append(.init(name: "expected_compile_failure", expectedState: "diagnostics", result: badCompile))
        guard badCompile.state == "diagnostics", !cancellation.isCancelled else { report.cancelled = cancellation.isCancelled; return report }
        let badLink = await adapter.execute(sources: ["missing.c": "extern int missing_symbol(void); int probe(void) { return missing_symbol(); }"],
            operations: [.compile(source: "missing.c", output: "missing.o", language: .c),
                         .link(objects: ["missing.o"], output: "missing.dylib", installName: "@rpath/missing.dylib")],
            cancellation: cancellation)
        report.outcomes.append(.init(name: "expected_link_failure", expectedState: "diagnostics", result: badLink))
        guard badLink.state == "diagnostics", !cancellation.isCancelled else { report.cancelled = cancellation.isCancelled; return report }
        let recovery = await adapter.execute(sources: ["recovery.c": "int recovered(void) { return 9; }"],
            operations: [.compile(source: "recovery.c", output: "recovery.o", language: .c),
                         .link(objects: ["recovery.o"], output: "recovery.dylib", installName: "@rpath/recovery.dylib")],
            cancellation: cancellation)
        report.outcomes.append(.init(name: "recovery_after_failures", expectedState: "success", result: recovery))
        report.cancelled = cancellation.isCancelled
        report.passed = !report.cancelled && report.outcomes.count == 5 && report.outcomes.allSatisfy(\.passed)
        return report
    }
}

/// No editable source/argv here: only the reviewed validation fixtures above.
struct EmbeddedAdapterDiagnosticsView: View {
    @State private var isRunning = false
    @State private var hasRun = false
    @State private var status: [String: String] = [:]
    @State private var token: EmbeddedAdapterCancellation?
    @State private var reportText = ""
    @State private var resultLabel = ""
    @State private var copied = false

    var body: some View {
        List {
            Section("受限执行适配器 · 验证版") {
                Label("通用 BuildProvider 保持禁用", systemImage: "lock.fill")
                Label("产物不执行、不发布到工程", systemImage: "checkmark.shield")
                Text("仅测试自包含 C/Objective-C → 本次对象链接 → Mach-O 检查 → 清理。Foundation、项目头文件和外部对象尚未接入。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button { start() } label: {
                    HStack {
                        Label("开始适配器验证", systemImage: "stethoscope")
                        Spacer()
                        if isRunning { ProgressView().accessibilityLabel("正在验证适配器") }
                    }
                }
                .disabled(isRunning || hasRun || status["verification"] != "passed" || status["sdk"] != "present")
                if isRunning {
                    Button("取消验证") { token?.cancel(); resultLabel = "已请求取消，当前编译/链接结束后清理" }
                }
                if !resultLabel.isEmpty { Text(resultLabel).font(.callout) }
            } header: {
                Text("固定操作流程")
            } footer: {
                Text("含成功请求、故意编译/链接失败、恢复和预取消测试。每个 App 进程最多 3 次适配器链接；RSS 达 384 MiB 或累计增加 64 MiB 即停止。请重新启动 App 后运行一次，不要先重复旧诊断。取消不会强行中断 LLVM/ld64。")
            }
            if !reportText.isEmpty {
                Section("适配器诊断 JSON") {
                    ScrollView(.horizontal) {
                        Text(reportText).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Button { UIPasteboard.general.string = reportText; copied = true } label: {
                        Label(copied ? "已复制适配器诊断 JSON" : "复制适配器诊断 JSON", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .navigationTitle("受限适配器验证")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { status = OMToolchain.capabilityStatus() }
        .onDisappear { token?.cancel() }
    }

    private func start() {
        let cancellation = EmbeddedAdapterCancellation()
        token = cancellation; isRunning = true; hasRun = true
        copied = false; reportText = ""; resultLabel = "正在验证受限操作流程…"
        Task {
            let report = await EmbeddedAdapterValidationReport.run(cancellation: cancellation)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.keyEncodingStrategy = .convertToSnakeCase
            reportText = (try? encoder.encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? "JSON encoding failed"
            resultLabel = report.cancelled ? "验证已取消，查看报告确认清理" :
                (report.passed ? "适配器固定操作验收通过" : "验证未通过或预算已耗尽，请发送 JSON")
            isRunning = false; token = nil
        }
    }
}
