import SwiftUI
import UIKit

/// Front-facing user flow for the homework coach. The camera is intentionally
/// inside a sheet: permission, ROI selection, start/stop and privacy status stay
/// visible instead of becoming an invisible background capture switch.
@MainActor
struct HomeworkCoachView: View {
    @StateObject private var controller: HomeworkCoachController
    @Environment(\.dismiss) private var dismiss
    @AppStorage(HomeworkHintPolicy.enabledKey) private var allowed = false

    init(vm: AIChatViewModel) {
        _controller = StateObject(wrappedValue: HomeworkCoachController(vm: vm))
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    permissionCard
                    settingCard
                    cameraCard
                    topicCard
                    statusCard
                    privacyCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("作业陪练")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") {
                        controller.stop()
                        dismiss()
                    }
                    .accessibilityLabel("关闭作业陪练")
                }
            }
        }
        .navigationViewStyle(.stack)
        .onChange(of: allowed) { value in
            if !value { controller.stop() }
        }
        .onDisappear { controller.stop() }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("固定摄像头辅导", systemImage: "camera.viewfinder")
                .font(.headline)
            Text("把手机固定对准本子。画面稳定变化或声音停顿后，应用只抓取作业区域的一张静帧，并向当前多模态模型请求一个下一步提示。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("不会保存连续视频；声音仅本地检测活动，不保存、不上传音频，也不转写或识别说话者。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var settingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("允许作业陪练", isOn: $allowed)
                .accessibilityHint("允许前台相机和麦克风活动检测；默认关闭")
            Divider()
            Toggle("自动抓拍并提示", isOn: Binding(
                get: { controller.isCoaching },
                set: { controller.setCoachingEnabled($0) }))
                .disabled(!controller.isCoaching && (!allowed || !controller.regionConfirmed || controller.phase != .preview))
                .accessibilityHint("需要先打开相机并确认作业区域")
            Text("默认关闭。自动提示只在前台运行，关闭或离开页面会立即停止。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("作业区域", systemImage: "rectangle.dashed")
                    .font(.headline)
                Spacer()
                Text(controller.phase.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HomeworkCameraRegionPreview(image: controller.preview,
                                        region: controller.region,
                                        editable: !controller.isCoaching,
                                        onRegionChanged: { controller.setRegion($0) })
                .frame(height: 310)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("作业区域取景框")
                .accessibilityValue(controller.preview == nil ? "未打开相机" : (controller.regionConfirmed ? "已确认" : "请拖动黄色框选作业区域"))

            HStack(spacing: 10) {
                Button {
                    if controller.phase == .stopped { controller.openPreview() } else { controller.stop() }
                } label: {
                    Label(controller.phase == .stopped ? "打开相机" : "停止相机",
                          systemImage: controller.phase == .stopped ? "camera" : "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled((!allowed && controller.phase == .stopped) || controller.phase == .stopping)
                .frame(minHeight: 44)

                Button {
                    controller.confirmRegion()
                } label: {
                    Label(controller.regionConfirmed ? "已确认" : "确认区域",
                          systemImage: controller.regionConfirmed ? "checkmark.circle.fill" : "checkmark.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(controller.preview == nil || controller.isCoaching)
                .frame(minHeight: 44)
            }
            Text(controller.regionConfirmed ? "已确认：只会裁剪框内画面。" : "拖动黄色框覆盖本子上的题目，再点击“确认区域”。")
                .font(.caption)
                .foregroundStyle(controller.regionConfirmed ? .green : .secondary)
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var topicCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("当前题目或步骤")
                    .font(.headline)
                Spacer()
                Button("清空") { controller.resetProblem() }
                    .font(.subheadline)
                    .disabled(controller.isCoaching)
            }
            TextEditor(text: $controller.topic)
                .frame(minHeight: 72, maxHeight: 120)
                .padding(6)
                .background(Color(UIColor.systemBackground), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
                .disabled(controller.isCoaching)
                .accessibilityLabel("当前题目或步骤")
            Text("可填写题目、年级或孩子正在尝试的步骤；不会修改聊天输入框。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("运行状态", systemImage: "waveform")
                    .font(.headline)
                Spacer()
                if controller.phase == .analyzing || controller.phase == .speaking {
                    ProgressView().accessibilityLabel("处理中")
                }
            }
            Text(controller.status)
                .font(.subheadline)
            if let error = controller.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if !controller.modelName.isEmpty {
                Text("模型：\(controller.modelName) · 已提示 \(controller.requestCount) 次 · 用量约 \(controller.usageTokenCount) tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let crop = controller.latestCrop {
                HStack(spacing: 10) {
                    Image(uiImage: crop)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 64)
                        .background(Color.black.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(controller.hint.isEmpty ? "正在等待提示…" : controller.hint)
                        .font(.body)
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var privacyCard: some View {
        Text("隐私与限制：仅前台工作，每次最长二十分钟。仅裁剪图、题目、最近六条会话文本和此前提示会发给当前所选模型，可能产生 API 费用；图像不写入相册或会话附件，但模型服务可能保留请求。声音仅触发抓拍，不理解孩子说的话，环境声也可能触发。提示播报时暂停采集，不支持语音打断。过滤不保证永不泄露答案，请家长监督。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }
}

private struct HomeworkCameraRegionPreview: View {
    let image: UIImage?
    let region: CGRect
    let editable: Bool
    let onRegionChanged: (CGRect) -> Void
    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let imageRect = fittedRect(imageSize: image?.size ?? CGSize(width: 3, height: 4), in: proxy.size)
            ZStack {
                Color.black
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.fill")
                            .font(.title)
                        Text("相机未打开")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                }
                let rect = CGRect(x: imageRect.minX + imageRect.width * region.minX,
                                  y: imageRect.minY + imageRect.height * region.minY,
                                  width: imageRect.width * region.width,
                                  height: imageRect.height * region.height)
                RoundedRectangle(cornerRadius: 4)
                    .stroke(editable ? Color.yellow : Color.green, lineWidth: 3)
                    .background(Color.white.opacity(0.001))
                    .frame(width: rect.width, height: rect.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            guard editable, image != nil else { return }
                            let start = dragStart ?? region
                            dragStart = start
                            onRegionChanged(HomeworkHintPolicy.normalizedRegion(CGRect(
                                x: start.minX + value.translation.width / max(imageRect.width, 1),
                                y: start.minY + value.translation.height / max(imageRect.height, 1),
                                width: start.width, height: start.height)))
                        }
                        .onEnded { _ in dragStart = nil })
                    .position(x: rect.midX, y: rect.midY)
                Text(editable ? "拖动框 / 右下角缩放" : "已确认作业区域")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(editable ? Color.yellow : Color.green, in: Capsule())
                    .position(x: rect.midX, y: max(imageRect.minY + 14, rect.minY + 14))
                    .allowsHitTesting(false)
                if editable, image != nil {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background(Color.yellow, in: Circle())
                        .gesture(DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                let start = dragStart ?? region
                                dragStart = start
                                onRegionChanged(HomeworkHintPolicy.normalizedRegion(CGRect(
                                    x: start.minX, y: start.minY,
                                    width: min(1 - start.minX, max(0.15, start.width + value.translation.width / max(imageRect.width, 1))),
                                    height: min(1 - start.minY, max(0.15, start.height + value.translation.height / max(imageRect.height, 1))))))
                            }.onEnded { _ in dragStart = nil })
                        .position(x: rect.maxX, y: rect.maxY)
                }
            }
        }
    }

    private func fittedRect(imageSize: CGSize, in size: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (size.width - fitted.width) / 2,
                      y: (size.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }
}
