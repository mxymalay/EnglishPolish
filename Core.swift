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

// 一条保存过的 AI 连接（历史连接）。密钥不在这里——它按地址存钥匙串。
struct AIProfile: Codable, Equatable, Identifiable {
    var endpoint: String
    var name: String
    var model: String
    var id: String { endpoint }
}

enum AIProfileStore {
    static let storageKey = "aiProfiles"

    static func load(_ defaults: UserDefaults = .standard) -> [AIProfile] {
        guard let data = defaults.data(forKey:storageKey),
              let profiles = try? JSONDecoder().decode([AIProfile].self,from:data) else { return [] }
        return profiles
    }

    static func save(_ profiles: [AIProfile], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data,forKey:storageKey)
    }

    // 同一地址只保留一条：换个名字或模型就是更新；新配置排最前，列表即使用历史。
    static func upsert(_ profile: AIProfile, into profiles: [AIProfile]) -> [AIProfile] {
        var result = profiles.filter { $0.endpoint != profile.endpoint }
        result.insert(profile,at:0)
        return result
    }

    static func remove(endpoint: String, from profiles: [AIProfile]) -> [AIProfile] {
        profiles.filter { $0.endpoint != endpoint }
    }

    // 没起名字的配置用 host[:port] 显示，让历史列表每行都能认出来。
    static func displayName(endpoint: String, name: String) -> String {
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard let url = URL(string:endpoint), let host = url.host else { return endpoint }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}

struct PolishResult: Codable {
    let ambiguous: Bool
    let question: String
    let options: [Suggestion]

    static func decode(_ data: Data) throws -> PolishResult {
        let result: PolishResult
        do { result = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw PolishError("AI 返回格式不完整，请重试。") }
        // Some local OpenAI-compatible models ignore the requested two-option limit
        // and return three or more valid alternatives. Keep the first two so the UI
        // remains deterministic while still rejecting incomplete/empty candidates.
        guard result.options.count >= 2,
              result.options.prefix(2).allSatisfy({ !$0.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (result.ambiguous ? !$0.chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : true) && $0.english.utf16.count <= 20000 }),
              !result.ambiguous || !result.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw PolishError("AI 未给出可确认的完整表达，请重试。") }
        return PolishResult(ambiguous: result.ambiguous, question: result.question, options: Array(result.options.prefix(2)))
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
    static func buttonRect(axRect: CGRect, composerRect: CGRect, sendRect: CGRect?, primaryHeight: CGFloat, visible: CGRect) -> CGRect {
        let size: CGFloat = 26
        // The send column's x is stable, but its AX frame can grow with a tall composer;
        // only trust its top edge while it still hugs the composer's bottom corner.
        let sendTop: CGFloat
        if let send = sendRect, composerRect.maxY - send.minY <= 80 {
            sendTop = send.minY
        } else {
            sendTop = composerRect.maxY - 40
        }
        let sendX = (sendRect?.midX ?? composerRect.maxX + 25) - size/2
        return CGRect(x: min(max(sendX, visible.minX + 6), visible.maxX - size - 6),
                      y: min(max(primaryHeight - sendTop + 12, visible.minY + 6), visible.maxY - size - 6),
                      width: size, height: size)
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

// MARK: - Message hover translation

enum MessageContentKind: Equatable {
    case text
    case file
    case media
    case link
    case other

    var canTranslate: Bool {
        switch self {
        // Attachments and links are intentionally excluded: a photo/video/document
        // card may contain a caption, and a URL may have a preview, but neither
        // should offer the message translation action. Only ordinary text remains
        // eligible for hover translation.
        case .text: return true
        case .file, .media, .link: return false
        case .other: return false
        }
    }
}

enum MessageHoverPlacement {
    static let actionSize: CGFloat = 32
    static let actionGap: CGFloat = 8
    static let defaultSystemActionCount = 2

    static func buttonRect(bubble: CGRect, visible: CGRect, systemActionCount: Int,
                           verticalAnchor: CGRect? = nil) -> CGRect {
        let count = max(0, systemActionCount)
        let groupWidth = actionSize * CGFloat(count + 1) + actionGap * CGFloat(count)
        let rightSlot = bubble.maxX + actionGap + CGFloat(count) * (actionSize + actionGap)
        let leftGroup = bubble.minX - actionGap - groupWidth
        let x: CGFloat
        if rightSlot + actionSize <= visible.maxX - 6 {
            x = rightSlot
        } else if leftGroup >= visible.minX + 6 {
            // Mirrored group: share and emoji remain between the bubble and slot 3.
            x = leftGroup
        } else {
            let preferred = rightSlot
            let maxX = max(visible.minX + 6, visible.maxX - actionSize - 6)
            x = min(max(preferred, visible.minX + 6), maxX)
        }
        let centerY = (verticalAnchor ?? bubble).midY
        return CGRect(x:x,y:centerY - actionSize/2,width:actionSize,height:actionSize)
    }
}

struct MessageBubble: Equatable {
    let text: String
    let rect: CGRect          // AX coordinates, top-left global origin
    let incoming: Bool
    let kind: MessageContentKind
    let contentRect: CGRect?  // AX frame for an image/video/file child, when exposed

    var canTranslate: Bool {
        incoming && kind.canTranslate && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var actionRect: CGRect { contentRect ?? rect }
}

// WhatsApp exposes each bubble as one AX cell whose AXDescription looks like
// "消息, <body>, <time>, 从X收到" (incoming) or
// "你的消息, <body>, <time>, 已发送到X, 已送达" (own). The body is not in AXValue.
enum BubbleDescription {
    static let typePrefixes: Set<String> = ["消息","你的消息","照片","视频","语音消息","语音","贴纸","GIF","动图","文件","文档","联系人","位置","实时位置","名片","音乐"]

    // Observed description formats (comma-separated):
    //   DM:     消息, <body>, <time>, 从X收到
    //   own:    你的消息, <body>, <time>, 已发送到X, 已送达
    //   group:  可能是X发来的消息, <body>, <time>, 在<群名>     (X may be "..")
    //   reply:  正在回复X.                          (quoted reply: no body exposed)
    //   media:  可能是X发来的照片/视频/语音/…, <caption>, <time>, …
    // The anchor is a type token or "…发来的消息"; everything before it is sender
    // metadata, everything after the body is time/status/location.
    static let mediaMarkers = ["发来的照片","发来的视频","发来的语音","发来的贴纸","发来的GIF","发来的文档","发来的名片","发来的位置"]

    private static func kind(for component: String) -> MessageContentKind? {
        if component.contains("发来的消息") || component == "消息" || component == "你的消息" {
            return .text
        }
        if component.contains("发来的文件") || component == "文件" || component == "你的文件" {
            return .file
        }
        if mediaMarkers.contains(where: { component.contains($0) }) {
            return .media
        }
        // WhatsApp sometimes exposes an outgoing attachment as “你的照片” or
        // “你发送的视频” instead of the incoming “发来的…” form. It is still
        // useful to classify it so it gets the light disabled action button.
        if component.hasPrefix("你的") || component.hasPrefix("你发送的") {
            if component.contains("文件") { return .file }
            if ["照片","视频","语音","贴纸","GIF","文档","名片","位置"].contains(where: { component.contains($0) }) {
                return .media
            }
            if component.contains("消息") { return .text }
        }
        if typePrefixes.contains(component) {
            if component == "文件" { return .file }
            if ["照片","视频","语音消息","语音","贴纸","GIF","动图","文档","联系人","位置","实时位置","名片","音乐"].contains(component) {
                return .media
            }
            return .text
        }
        return nil
    }

    static func classify(_ raw: String) -> (incoming: Bool, kind: MessageContentKind)? {
        let text = raw.filter { $0 != "\u{200E}" }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let components = text.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }
        var incoming = !(components[0].hasPrefix("你的") || components[0].hasPrefix("你发送的"))
        for component in components {
            if let contentKind = kind(for: component) {
                if component.hasPrefix("你的") || component.hasPrefix("你发送的") { incoming = false }
                return (incoming, contentKind)
            }
        }
        return nil
    }

    // Quoted-reply bubbles describe themselves across lines:
    //   正在回复<sender>.
    //   <this reply's own description>   ← the reply body lives here
    //   引用消息.
    //   <quoted message body>
    static func replyOwnDescription(_ raw: String) -> String? {
        let cleaned = raw.filter { $0 != "\u{200E}" }
        let lines = cleaned.components(separatedBy:"\n")
            .map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let replyIndex = lines.firstIndex(where:{ $0.hasPrefix("正在回复") }),
              replyIndex + 1 < lines.count,
              !lines[replyIndex+1].hasPrefix("引用消息") else { return nil }
        return lines[replyIndex+1]
    }

    static func parse(_ raw: String) -> (body: String, incoming: Bool, kind: MessageContentKind)? {
        let text = raw.filter { $0 != "\u{200E}" }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let components = text.components(separatedBy:", ").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
        guard components.count >= 2 else { return nil }
        var bodyStart: Int? = nil
        var incoming = !(components[0].hasPrefix("你的") || components[0].hasPrefix("你发送的"))
        var contentKind: MessageContentKind = .other
        for (index, component) in components.enumerated() {
            if component.contains("正在回复") { return nil }
            if let detected = kind(for: component) {
                bodyStart = index + 1
                contentKind = detected
                if component.hasPrefix("你的") || component.hasPrefix("你发送的") { incoming = false }
                break
            }
        }
        guard let anchor = bodyStart, anchor < components.count else { return nil }
        var bodyEnd = components.count
        // Strip trailing time / status / chat-location components. A component counts
        // as a timestamp only when it is made of date/time characters outright, or is
        // a day/time word followed by clock text — bodies that merely START with a
        // time word (凌晨1点见) stay in the translation.
        while bodyEnd > anchor {
            let last = components[bodyEnd-1]
            let pureDateTime = last.range(of: "^[\\d年月日时分秒:：\\s]+$",options:.regularExpression) != nil
            let token = "^(昨天|今天|前天|星期[一二三四五六日末]|周[一二三四五六日末]|上午|下午|中午|凌晨|年?\\d+月\\d+日|\\d+年\\d+月\\d+日)"
            let startsWithToken = last.range(of: token,options:.regularExpression) != nil
            let remainderIsClock = last.range(of: token + "\\s*(上午|下午|中午|凌晨)?\\s*[\\d:：\\s]{0,8}$",options:.regularExpression) != nil
            let looksLikeTime = pureDateTime || (startsWithToken && remainderIsClock)
            let looksLikeFileSize = contentKind == .file && last.range(of: "^[\\d.]+\\s*(B|KB|MB|GB|TB|字节|千字节|兆字节|吉字节)$", options: [.regularExpression, .caseInsensitive]) != nil
            if looksLikeTime
                || looksLikeFileSize
                || last.hasPrefix("在") || last.hasPrefix("从") && last.hasSuffix("收到")
                || last.contains("已发送到") || last.hasPrefix("已送达") || last.hasPrefix("已读")
                || last.hasPrefix("正在发送") || last.hasPrefix("挂起") {
                if last.contains("已发送到") || last.hasPrefix("已送达") || last.hasPrefix("已读") { incoming = false }
                bodyEnd -= 1
                continue
            }
            break
        }
        // Direction is decided from the leading “你的…” marker or a delivery
        // status. Do not search the full body for these words: an incoming message
        // can legitimately mention “你的消息” in its text.
        if !incoming { return nil }
        let body = components[anchor..<bodyEnd].joined(separator:", ").trimmingCharacters(in:.whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let finalKind: MessageContentKind
        if contentKind == .text && (body.contains("链接") || body.range(of:"https?://",options:.regularExpression) != nil || body.localizedCaseInsensitiveContains("join conversation")) {
            finalKind = .link
        } else {
            finalKind = contentKind
        }
        return (body, incoming, finalKind)
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
