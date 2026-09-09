import Foundation
import CoreGraphics

struct PolishError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Suggestion: Codable, Equatable {
    let english: String
    let chinese: String
}

struct PolishResult: Codable {
    let ambiguous: Bool
    let question: String
    let options: [Suggestion]

    static func decode(_ data: Data) throws -> PolishResult {
        let result: PolishResult
        do { result = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw PolishError("AI 返回格式不完整，请重试。") }
        guard result.options.count == 2,
              result.options.allSatisfy({ !$0.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.english.utf16.count <= 20000 }),
              !result.ambiguous || !result.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw PolishError("AI 未给出可确认的完整表达，请重试。") }
        return result
    }
}

struct DraftIdentity: Equatable {
    let window: String
    let chat: String
    let text: String
    let field: String
    func mayReplace(with current: Self) -> Bool {
        self == current && !chat.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

func lastCharacterRange(_ text: String) -> NSRange? {
    let value = text as NSString
    guard value.length > 0 else { return nil }
    return value.rangeOfComposedCharacterSequence(at: value.length - 1)
}

enum Placement {
    static func buttonRect(axRect: CGRect, composerRect: CGRect, primaryHeight: CGFloat, visible: CGRect) -> CGRect {
        let size: CGFloat = 26
        let x = min(max(axRect.maxX + 6, visible.minX + 6), visible.maxX - size - 6)
        // AX coordinates start at the top. Keep the entire trigger below the composer so
        // a downward popover cannot cover the draft text.
        let y = min(max(primaryHeight - composerRect.maxY - size - 4, visible.minY + 6), visible.maxY - size - 6)
        return CGRect(x: x, y: y, width: size, height: size)
    }

    static func shouldOpenCandidatesBelow(anchor: CGRect, visible: CGRect, requiredHeight: CGFloat = 170) -> Bool {
        let spaceBelow = anchor.minY - visible.minY
        let spaceAbove = visible.maxY - anchor.maxY
        // Prefer downward placement when it has normal dictionary-popover room.
        // Near the bottom edge, use the roomier upper side instead.
        return spaceBelow >= requiredHeight || spaceBelow >= spaceAbove
    }

    static func candidateRect(anchor: CGRect, contentSize: CGSize, visible: CGRect, opensBelow: Bool) -> CGRect {
        let margin: CGFloat = 6, gap: CGFloat = 2
        let width = min(contentSize.width, max(1,visible.width-margin*2))
        let room = opensBelow
            ? anchor.minY-visible.minY-gap-margin
            : visible.maxY-anchor.maxY-gap-margin
        let height = min(contentSize.height,max(1,room))
        let x = min(max(anchor.midX-width/2,visible.minX+margin),visible.maxX-width-margin)
        let y = opensBelow ? anchor.minY-gap-height : anchor.maxY+gap
        return CGRect(x:x,y:y,width:width,height:height)
    }
}

enum SessionPolicy {
    static func isReady(_ session: [String:Any]) -> Bool {
        guard session["kCGSSessionOnConsoleKey"] as? Bool == true,
              session["kCGSessionLoginDoneKey"] as? Bool == true else { return false }
        if let lock = session["CGSSessionScreenIsLocked"] { return (lock as? Bool) == false }
        return true
    }
}

struct ReplacementLease {
    private(set) var valid = true
    mutating func observeActivation(isOwnApp: Bool) { if !isOwnApp { valid = false } }
}

enum FloatingButtonStatus: Equatable {
    case starting
    case paused
    case desktopUnavailable
    case accessibilityNeeded
    case whatsAppNotRunning
    case whatsAppNotActive
    case noFocusedChat
    case composerUnavailable
    case emptyDraft
    case previewOpen
    case ready

    var menuTitle: String {
        switch self {
        case .starting: return "轻语：正在检查 WhatsApp…"
        case .paused: return "轻语：浮动按钮已暂停"
        case .desktopUnavailable: return "轻语：等待可用的桌面会话"
        case .accessibilityNeeded: return "轻语：需要辅助功能权限"
        case .whatsAppNotRunning: return "轻语：请先打开 WhatsApp"
        case .whatsAppNotActive: return "轻语：请先切换到 WhatsApp"
        case .noFocusedChat: return "轻语：请先打开一个聊天"
        case .composerUnavailable: return "轻语：未找到消息输入框"
        case .emptyDraft: return "轻语：输入英文后显示 ✨"
        case .previewOpen: return "轻语：润色窗口打开时隐藏 ✨"
        case .ready: return "轻语：✨ 已显示在输入框旁"
        }
    }
}
