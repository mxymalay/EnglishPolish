import AppKit
import ApplicationServices

struct DraftSnapshot {
    let identity: DraftIdentity
    let element: AXUIElement
    let window: AXUIElement
    let header: AXUIElement
    let pid: pid_t
    let bounds: CGRect
    let exactCharacter: Bool
}

struct DraftProbe {
    let status: FloatingButtonStatus
    let snapshot: DraftSnapshot?
}

final class WhatsAppBridge {
    static let bundleID = "net.whatsapp.WhatsApp"
    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    private func string(_ element: AXUIElement, _ attribute: String) -> String {
        value(element, attribute) as? String ?? ""
    }
    private func element(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }
    private func find(_ root: AXUIElement, id: String, budget: inout Int, depth: Int = 0) -> AXUIElement? {
        guard budget > 0, depth < 18 else { return nil }
        budget -= 1
        let identifier = string(root, kAXIdentifierAttribute)
        if identifier == id { return root }
        // Never descend into conversation history or the contact list.
        if identifier == "ChatMessagesTableView" || identifier == "ChatListView_TableView" { return nil }
        guard let children = value(root, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children { if let found = find(child, id:id, budget:&budget, depth:depth+1) { return found } }
        return nil
    }
    private func rect(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element,kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = value(element,kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin:point,size:size)
    }
    private func endRect(_ element: AXUIElement, text: String) -> CGRect? {
        guard let ns = lastCharacterRange(text) else { return nil }
        var range = CFRange(location:ns.location, length:ns.length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element,kAXBoundsForRangeParameterizedAttribute as CFString,parameter,&result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(result as! AXValue,.cgRect,&rect), rect.height > 0 else { return nil }
        return rect
    }

    func probe(requireFrontmost: Bool = true) -> DraftProbe {
        guard AXIsProcessTrusted() else { return DraftProbe(status:.accessibilityNeeded,snapshot:nil) }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier:Self.bundleID).first,
              !app.isTerminated, !app.isHidden else { return DraftProbe(status:.whatsAppNotRunning,snapshot:nil) }
        guard !requireFrontmost || NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return DraftProbe(status:.whatsAppNotActive,snapshot:nil)
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp,0.2)
        guard let window = element(value(axApp,kAXFocusedWindowAttribute)),
              (value(window,kAXMinimizedAttribute) as? Bool) != true else { return DraftProbe(status:.noFocusedChat,snapshot:nil) }
        var budget = 250
        guard let composer = find(window,id:"ChatBar_ComposerTextView",budget:&budget),
              let fieldRect = rect(composer) else { return DraftProbe(status:.composerUnavailable,snapshot:nil) }
        budget = 250
        guard let header = find(window,id:"NavigationBar_HeaderViewButton",budget:&budget) else { return DraftProbe(status:.noFocusedChat,snapshot:nil) }
        let chat = [string(header,kAXTitleAttribute), string(header,kAXDescriptionAttribute), string(header,kAXValueAttribute)].joined(separator:"|")
        guard !chat.replacingOccurrences(of:"|",with:"").isEmpty else { return DraftProbe(status:.noFocusedChat,snapshot:nil) }
        let text = string(composer,kAXValueAttribute)
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return DraftProbe(status:.emptyDraft,snapshot:nil) }
        let end = endRect(composer,text:text)
        // When character bounds are unavailable, place the button just above the input's right edge.
        let anchor = end.flatMap { fieldRect.intersects($0) ? $0 : nil }
        let fallback = CGRect(x:fieldRect.maxX-38,y:fieldRect.minY-38,width:0,height:0)
        let identity = DraftIdentity(window:String(CFHash(window)),chat:chat,text:text,field:String(CFHash(composer)))
        return DraftProbe(status:.ready,snapshot:DraftSnapshot(identity:identity,element:composer,window:window,header:header,pid:app.processIdentifier,bounds:anchor ?? fallback,exactCharacter:anchor != nil))
    }

    func snapshot(requireFrontmost: Bool = true) -> DraftSnapshot? {
        probe(requireFrontmost:requireFrontmost).snapshot
    }

    func replace(_ original: DraftSnapshot, with text: String) throws {
        guard let current = snapshot(requireFrontmost:false),
              original.pid == current.pid,
              CFEqual(original.window,current.window), CFEqual(original.element,current.element), CFEqual(original.header,current.header),
              original.identity.mayReplace(with:current.identity) else {
            throw PolishError("原文或聊天已变化，已停止替换。请回到 WhatsApp，重新点击 ✨。也可以复制此结果。")
        }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(current.element,kAXValueAttribute as CFString,&settable) == .success, settable.boolValue else {
            throw PolishError("此版本 WhatsApp 不允许直接替换，请点击“复制英文”后自行粘贴。")
        }
        // AX changes text only; no keyboard synthesis, pasteboard mutation or Send action.
        guard AXUIElementSetAttributeValue(current.element,kAXValueAttribute as CFString,text as CFString) == .success else {
            throw PolishError("WhatsApp 未接受替换，请复制英文后自行粘贴。")
        }
        guard string(current.element,kAXValueAttribute) == text else {
            throw PolishError("未能确认替换结果，请检查 WhatsApp 输入框。")
        }
    }
}
