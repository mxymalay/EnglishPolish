import SwiftUI

// Hover translate button styled like WhatsApp's own reaction button: a small
// circular material disc that sits to the right of the hovered message bubble.
struct HoverTranslateButton: View {
    @ObservedObject var model: TranslateModel
    let text: String
    let enabled: Bool
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        // Mirrors WhatsApp's reaction button: shows on hover as a light disabled disc,
        // turning into a solid dark clickable one once the message is known to carry
        // translatable text. While translating, the real router status (polled from
        // /status) decides between "translating" and "waiting for the model switch".
        let busy = enabled && model.target?.text == text && model.phase == .busy
        let waiting = model.waitingStatus != nil
        Button(action: action) {
            ZStack {
                if enabled {
                    Circle().fill(Color(nsColor:.systemGray).opacity(0.75))
                } else {
                    Circle().fill(.regularMaterial)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.06)))
                }
                if busy {
                    if waiting {
                        Image(systemName: "hourglass")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Image(systemName: "translate")
                        .font(.system(size: 13, weight: .medium))
                        .symbolRenderingMode(hovered && enabled ? .multicolor : .monochrome)
                        .foregroundStyle(enabled ? Color.white : Color.secondary.opacity(0.45))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .frame(width: 32, height: 32)
        .onHover { hovered = $0 }
        .help(enabled ? (busy ? (model.waitingStatus ?? "正在翻译…") : "翻译这条消息") : "这条消息没有可翻译的文字")
        .accessibilityLabel(enabled ? "翻译这条消息" : "无翻译文字")
    }
}
