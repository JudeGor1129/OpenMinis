import Foundation
import CoreGraphics

// Compiles the production policy, never a duplicated implementation.
// Run bash scripts/ios15/check-homework-coach-source.sh on macOS.
var failures = 0
func check(_ name: String, _ result: Bool) {
    print("\(result ? "PASS" : "FAIL"): \(name)")
    if !result { failures += 1 }
}
let r = CGRect(x: 0, y: 0, width: 1, height: 1)
let a = [UInt8](repeating: 120, count: 1024)
var b = a
for index in 0..<100 { b[index] = 20 }
var gate = HomeworkFrameGate()
for tick in 0...6 {
    check("unchanged frame does not upload \(tick)", gate.observe(a, region: r, now: Double(tick) * 0.4) == nil)
}
gate.voice(true)
check("speaking does not upload", gate.observe(a, region: r, now: 2.8) == nil)
gate.voice(false)
check("speech end captures stable image", gate.observe(a, region: r, now: 3.2) != nil)
gate.voice(true); gate.voice(false)
check("cooldown blocks next utterance", gate.observe(a, region: r, now: 3.6) == nil)
for tick in 10...37 { _ = gate.observe(a, region: r, now: Double(tick) * 0.4) }
check("pending utterance survives cooldown", gate.observe(a, region: r, now: 15.3) != nil)
check("new movement not uploaded while moving", gate.observe(b, region: r, now: 16) == nil)
for tick in 41...68 { _ = gate.observe(b, region: r, now: Double(tick) * 0.4) }
check("changed region uploaded after stable and cooldown", gate.observe(b, region: r, now: 27.4) != nil)
check("out of order frame ignored", gate.observe(a, region: r, now: 26) == nil)
gate.reset()
_ = gate.observe(a, region: r, now: 30)
check("sampling gap must re-stabilize", gate.observe(b, region: r, now: 40) == nil)
let narrow = HomeworkHintPolicy.normalizedRegion(CGRect(x: -2, y: 2, width: 0.01, height: 4))
check("ROI clamps to bounds and minimum", narrow.minX == 0 && narrow.maxY <= 1 && narrow.width >= 0.15)
let crop = HomeworkHintPolicy.pixelRect(region: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.3), imageSize: CGSize(width: 100, height: 200))
check("preview and crop have same top row", crop == CGRect(x: 10, y: 40, width: 40, height: 60))
func response(_ value: String) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: ["kind": "question", "hint": value]), encoding: .utf8)!
}
check("one short question accepted", HomeworkHintPolicy.validatedHint(response("你能先找出题目要求比较的对象吗？")) != nil)
for bad in ["答案是三？", "先算 5+2？", "结果等于五？", "你想到了吗？再算一下？", "你知道吗\n再试试？", "正确选项应该选甲？"] {
    check("unsafe question blocked: \(bad)", HomeworkHintPolicy.validatedHint(response(bad)) == nil)
}
check("malformed reply rejected", HomeworkHintPolicy.validatedHint("```json\n{}\n```") == nil)
check("extra fields rejected", HomeworkHintPolicy.validatedHint("{\"kind\":\"question\",\"hint\":\"你能先观察题目吗？\",\"answer\":\"secret\"}") == nil)
exit(failures == 0 ? 0 : 1)
