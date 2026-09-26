import SwiftUI

/// 一条「为什么现在不能用」的说明。
///
/// 轻语以前失败时只写菜单栏标题，而用户正看着 WhatsApp，根本看不到——于是表现
/// 成「点了没反应」。任何一次 AI 失败都要落到这个气泡上，锚在输入框旁边。
struct AIReason: Equatable {
    let title: String
    let message: String
    var hint: String = ""
    var retryable: Bool = true

    static let unavailableTitle = "AI 暂时不可用"
}

@MainActor
final class ReasonModel: ObservableObject {
    @Published private(set) var reason: AIReason?
    var isShowing: Bool { reason != nil }
    func show(_ reason: AIReason) { self.reason = reason }
    func clear() { reason = nil }
}

struct ReasonBubbleView: View {
    @ObservedObject var model: ReasonModel
    var retry: () -> Void
    var settings: () -> Void
    var close: () -> Void

    var body: some View {
        if let reason = model.reason {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                    Text(reason.title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                Text(reason.message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !reason.hint.isEmpty {
                    Text(reason.hint).font(.system(size: 11)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if reason.retryable { Button("重试", action: retry) }
                    Button("AI 设置", action: settings)
                    Spacer()
                    Button("关闭", action: close)
                }.controlSize(.small)
            }
            .padding(12).frame(width: 330)
        }
    }
}

struct ReasonPanelView: View {
    @ObservedObject var model: ReasonModel
    let opensBelow: Bool
    var retry: () -> Void
    var settings: () -> Void
    var close: () -> Void

    var body: some View {
        ReasonBubbleView(model:model,retry:retry,settings:settings,close:close)
            .padding(.top,opensBelow ? 9 : 0)
            .padding(.bottom,opensBelow ? 0 : 9)
            .background(.regularMaterial,in:CandidateBubbleShape(opensBelow:opensBelow))
            .overlay(CandidateBubbleShape(opensBelow:opensBelow).stroke(.primary.opacity(0.13),lineWidth:0.7))
            .shadow(color:.black.opacity(0.22),radius:12,y:opensBelow ? 3 : -3)
            .padding(12)
            .onExitCommand(perform: close)
    }
}
