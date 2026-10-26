import Foundation
import CoreGraphics

// Uses the production implementation. Run the macOS quick-check script.
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
    check("unchanged frame does not upload \(tick)", gate.observe(a, region: r, now: Double(tick) * 0.4, allowChangeCapture: false) == nil)
}
gate.voice(true)
check("speaking does not upload", gate.observe(a, region: r, now: 2.8, questionPending: true) == nil)
gate.voice(false)
check("noise without recognized question does not prompt model", gate.observe(a, region: r, now: 3.0, allowChangeCapture: false) == nil)
check("recognized question captures stable image", gate.observe(a, region: r, now: 3.2, questionPending: true, allowChangeCapture: false) != nil)
check("next spoken followup is not blocked by visual cooldown", gate.observe(a, region: r, now: 3.6, questionPending: true, allowChangeCapture: false) != nil)
check("movement waits for stable frame", gate.observe(b, region: r, now: 4, allowChangeCapture: false) == nil)
for tick in 11...16 { _ = gate.observe(b, region: r, now: Double(tick) * 0.4, allowChangeCapture: false) }
check("writing alone does not interrupt teacher mode", gate.observe(b, region: r, now: 6.8, allowChangeCapture: false) == nil)
check("backwards frame ignored", gate.observe(a, region: r, now: 6, questionPending: true) == nil)
gate.reset()
_ = gate.observe(a, region: r, now: 20)
check("sampling gap restabilizes", gate.observe(b, region: r, now: 30, questionPending: true) == nil)
let bounded = HomeworkHintPolicy.normalizedRegion(CGRect(x: -2, y: 2, width: 0.01, height: 4))
check("ROI bounded", bounded.minX == 0 && bounded.maxY <= 1 && bounded.width >= 0.15)
let crop = HomeworkHintPolicy.pixelRect(region: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.3), imageSize: CGSize(width: 100, height: 200))
check("crop uses same top row as preview", crop == CGRect(x: 10, y: 40, width: 40, height: 60))
func response(_ explanation: String, next: String = "先找到题目要比较的对象。", question: String = "你能试着说出自己的想法吗？") -> String {
    String(data: try! JSONSerialization.data(withJSONObject: ["explanation": explanation, "next_step": next, "check_question": question]), encoding: .utf8)!
}
let lesson = HomeworkHintPolicy.validatedLesson(response("分数比较先看单位是否相同。例如把蛋糕分成 4 份与 8 份，每份的大小不同。"))
check("multi-sentence explanation and numeric examples allowed", lesson != nil)
check("teacher output carries explanation and next step", lesson?.spokenText.contains("先找到") == true)
check("direct final answer blocked", HomeworkHintPolicy.validatedLesson(response("这道题的答案是五。")) == nil)
check("overlong lecture blocked", HomeworkHintPolicy.validatedLesson(response(String(repeating: "讲", count: 450))) == nil)
check("old question-only schema rejected", HomeworkHintPolicy.validatedLesson("{\"kind\":\"question\",\"hint\":\"观察题目好吗？\"}") == nil)
check("malformed response blocked", HomeworkHintPolicy.validatedLesson("```json\n{}\n```") == nil)
check("extra answer field blocked", HomeworkHintPolicy.validatedLesson("{\"explanation\":\"解释\",\"next_step\":\"尝试\",\"check_question\":\"试试？\",\"answer\":\"secret\"}") == nil)
exit(failures == 0 ? 0 : 1)
