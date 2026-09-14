import AppKit
import ApplicationServices

struct DraftSnapshot {
    let identity: DraftIdentity
    let element: AXUIElement
    let window: AXUIElement
    let header: AXUIElement
    let pid: pid_t
    let bounds: CGRect
    let composerBounds: CGRect
    let sendBounds: CGRect?
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

    func probe(requireFrontmost: Bool = true, allowEmpty: Bool = false) -> DraftProbe {
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
        if !allowEmpty, text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            return DraftProbe(status:.emptyDraft,snapshot:nil)
        }
        let end = endRect(composer,text:text)
        // When character bounds are unavailable, place the button just above the input's right edge.
        let anchor = end.flatMap { fieldRect.intersects($0) ? $0 : nil }
        let fallback = CGRect(x:fieldRect.maxX-38,y:fieldRect.minY-38,width:0,height:0)
        let identity = DraftIdentity(window:String(CFHash(window)),chat:chat,text:text,field:String(CFHash(composer)))
        return DraftProbe(status:.ready,snapshot:DraftSnapshot(identity:identity,element:composer,window:window,header:header,pid:app.processIdentifier,bounds:anchor ?? fallback,composerBounds:fieldRect,sendBounds:sendRect(near:composer),exactCharacter:anchor != nil))
    }

    // The send button is a sibling of the composer; locating it precisely keeps the
    // trigger neatly stacked above it.
    private func sendRect(near composer: AXUIElement) -> CGRect? {
        guard let parent = element(value(composer,kAXParentAttribute)),
              let children = value(parent,kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children where string(child,kAXIdentifierAttribute).lowercased().contains("send") {
            if let frame = rect(child) { return frame }
        }
        return nil
    }

    // Temporary diagnostic: dump the composer area's buttons with exact frames.
    func dumpComposerButtons() -> String? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier:Self.bundleID).first,
              !app.isTerminated else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp,1.0)
        guard let window = element(value(axApp,kAXFocusedWindowAttribute)) else { return nil }
        var budget = 600
        guard let composer = find(window,id:"ChatBar_ComposerTextView",budget:&budget),
              let composerRect = rect(composer) else { return "无输入框" }
        var lines = ["composer=\(composerRect)"]
        if let parent = element(value(composer,kAXParentAttribute)) {
            let grandparent: AXUIElement? = element(value(parent,kAXParentAttribute))
            for container in [parent] + (grandparent.map { [$0] } ?? []) {
                if let children = value(container,kAXChildrenAttribute) as? [AXUIElement] {
                    for child in children {
                        let id = string(child,kAXIdentifierAttribute)
                        let role = string(child,kAXRoleAttribute)
                        if let frame = rect(child) {
                            lines.append("[\(role)] id=\(id.isEmpty ? "-" : id) \(frame)")
                        }
                    }
                }
            }
        }
        return lines.joined(separator:"\n")
    }

    // Temporary diagnostic: snapshot the message table's buttons/cells with frames.
    func dumpMessageButtons() -> String? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier:Self.bundleID).first,
              !app.isTerminated else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp,0.5)
        let windows = (value(axApp,kAXWindowsAttribute) as? [AXUIElement]) ?? []
        guard let window = windows.first(where:{ !string($0,kAXTitleAttribute).isEmpty }) ?? windows.first else { return "无窗口" }
        var budget = 500
        guard let table = find(window,id:"ChatMessagesTableView",budget:&budget) else { return "无消息区" }
        var lines: [String] = []
        var walkBudget = 2500
        func walk(_ element: AXUIElement, depth: Int) {
            guard walkBudget > 0, depth < 24 else { return }
            walkBudget -= 1
            let role = string(element,kAXRoleAttribute)
            let identifier = string(element,kAXIdentifierAttribute)
            if true {
                if let frame = rect(element) {
                    let desc = string(element,kAXDescriptionAttribute)
                    lines.append("[\(role)] id=\(identifier.isEmpty ? "-" : identifier) \(frame) descFull=\(desc.replacingOccurrences(of:"\n",with:" ⏎ "))")
                }
            }
            guard let children = value(element,kAXChildrenAttribute) as? [AXUIElement] else { return }
            for child in children { walk(child,depth:depth+1) }
        }
        walk(table,depth:0)
        // Probe whether full text hides behind parameterized string-for-range.
        var budget2 = 800
        func firstCell(_ root: AXUIElement, depth: Int) -> AXUIElement? {
            guard budget2 > 0, depth < 24 else { return nil }
            budget2 -= 1
            if string(root,kAXIdentifierAttribute) == "WAMessageBubbleTableViewCell" { return root }
            guard let children = value(root,kAXChildrenAttribute) as? [AXUIElement] else { return nil }
            for child in children { if let found = firstCell(child,depth:depth+1) { return found } }
            return nil
        }
        if let cell = firstCell(table,depth:0) {
            var n: CFTypeRef?
            AXUIElementCopyAttributeValue(cell,kAXNumberOfCharactersAttribute as CFString,&n)
            let count = (n as? NSNumber)?.intValue ?? 0
            var range = CFRange(location:0,length:count)
            if let param = AXValueCreate(.cfRange,&range) {
                var out: CFTypeRef?
                AXUIElementCopyParameterizedAttributeValue(cell,kAXStringForRangeParameterizedAttribute as CFString,param,&out)
                lines.append("cell chars=\(count) stringForRange=\(out as? String ?? "nil")")
            }
            let raw = string(cell,kAXDescriptionAttribute)
            if let parsed = BubbleDescription.parse(raw), let frame = rect(cell) {
                let bounds = contentRect(cell,raw:raw,body:parsed.body,cellRect:frame,kind:parsed.kind)
                lines.append("cell parsedKind=\(parsed.kind) body=\(parsed.body) contentRect=\(bounds.map(String.init(describing:)) ?? "nil")")
            }
            if let cellFrame = rect(cell) {
                lines.append("hoverActionAnchor=\(hoverActionAnchor(near:cellFrame).map(String.init(describing:)) ?? "nil")")
            }
        }
        return lines.joined(separator:"\n")
    }

    // WhatsApp renders its share/emoji controls in a hover layer that is not a
    // descendant of the message cell. Hit-test the system AX element at a small
    // grid beside the cell to read those real button frames and use their shared
    // vertical center as our anchor.
    func hoverActionAnchor(near cellRect: CGRect) -> CGRect? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier:Self.bundleID).first,
              !app.isTerminated else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp,0.3)
        let windows = (value(axApp,kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var treeFrames: [CGRect] = []
        var treeBudget = 5000
        func walk(_ element: AXUIElement, depth: Int) {
            guard treeBudget > 0, depth < 24 else { return }
            treeBudget -= 1
            if let frame = rect(element) {
                let role = string(element,kAXRoleAttribute)
                let nearCell = frame.width >= 20 && frame.height >= 20
                    && frame.width <= 100 && frame.height <= 100
                    && frame.minX >= cellRect.maxX - 12 && frame.minX <= cellRect.maxX + 180
                    && frame.midY >= cellRect.minY - 16 && frame.midY <= cellRect.maxY + 16
                if nearCell && (role == "AXButton" || role == "AXLink" || role == "AXGroup")
                    && !treeFrames.contains(where:{ $0.insetBy(dx:-2,dy:-2).intersects(frame) }) {
                    treeFrames.append(frame)
                }
            }
            guard let children = value(element,kAXChildrenAttribute) as? [AXUIElement] else { return }
            for child in children { walk(child,depth:depth+1) }
        }
        for window in windows { walk(window,depth:0) }
        if !treeFrames.isEmpty {
            let minX = treeFrames.map(\.minX).min() ?? 0
            let minY = treeFrames.map(\.minY).min() ?? 0
            let maxX = treeFrames.map(\.maxX).max() ?? 0
            let maxY = treeFrames.map(\.maxY).max() ?? 0
            return CGRect(x:minX,y:minY,width:maxX-minX,height:maxY-minY)
        }

        let system = AXUIElementCreateSystemWide()
        var frames: [CGRect] = []
        let xStart = max(0, cellRect.maxX - 6)
        let xEnd = cellRect.maxX + 180
        let yStart = max(0, cellRect.minY - 12)
        let yEnd = cellRect.maxY + 12
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0

        func probe(_ x: CGFloat, _ pointY: CGFloat) {
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(x), Float(pointY), &hit) == .success,
                  let hit,
                  let rawFrame = rect(hit) else { return }
            let frameCandidates = [rawFrame,
                CGRect(x:rawFrame.minX,y:screenHeight-rawFrame.maxY,width:rawFrame.width,height:rawFrame.height)]
            guard let frame = frameCandidates.first(where: {
                $0.width >= 20 && $0.height >= 20 && $0.width <= 100 && $0.height <= 100
                    && $0.minX >= cellRect.maxX - 12 && $0.minX <= cellRect.maxX + 180
                    && $0.midY >= cellRect.minY - 16 && $0.midY <= cellRect.maxY + 16
            }) else { return }
            let role = string(hit,kAXRoleAttribute)
            guard role == "AXButton" || role == "AXLink" || role == "AXGroup" else { return }
            if !frames.contains(where:{ $0.insetBy(dx:-2,dy:-2).intersects(frame) }) {
                frames.append(frame)
            }
        }

        var y = yStart
        while y <= yEnd {
            var x = xStart
            while x <= xEnd {
                probe(x,y)
                if screenHeight > 0 { probe(x,screenHeight-y) }
                x += 10
            }
            y += 10
        }
        guard !frames.isEmpty else { return nil }
        let minX = frames.map(\.minX).min() ?? 0
        let minY = frames.map(\.minY).min() ?? 0
        let maxX = frames.map(\.maxX).max() ?? 0
        let maxY = frames.map(\.maxY).max() ?? 0
        return CGRect(x:minX,y:minY,width:maxX-minX,height:maxY-minY)
    }

    // Reads visible message bubbles for the hover-translate button. Bubbles are
    // rendered by WhatsApp and never modified; the translation shows in our own panel.
    func scanMessages() -> [MessageBubble] {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier:Self.bundleID).first,
              !app.isTerminated, !app.isHidden else { return [] }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp,0.4)
        let windows = (value(axApp,kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var bubbles: [MessageBubble] = []
        for window in windows {
            if (value(window,kAXMinimizedAttribute) as? Bool) == true { continue }
            var budget = 400
            guard let table = find(window,id:"ChatMessagesTableView",budget:&budget) else { continue }
            var walkBudget = 3000
            collectBubbles(table,into:&bubbles,budget:&walkBudget,depth:0)
        }
        return bubbles
    }

    private func collectBubbles(_ root: AXUIElement, into bubbles: inout [MessageBubble], budget: inout Int, depth: Int) {
        guard budget > 0, depth < 24 else { return }
        budget -= 1
        if string(root,kAXIdentifierAttribute) == "WAMessageBubbleTableViewCell" {
            let raw = string(root,kAXDescriptionAttribute)
            let description = BubbleDescription.replyOwnDescription(raw) ?? raw
            if let frame = rect(root) {
                // Translatable messages carry their body; everything else (media,
                // undecodable formats, own messages) lands with empty text and only
                // shows the disabled hover button, mirroring the reaction button.
                if let parsed = BubbleDescription.parse(description) {
                    let contentRect = contentRect(root,raw:description,body:parsed.body,cellRect:frame,kind:parsed.kind)
                    bubbles.append(MessageBubble(text:parsed.body,rect:frame,incoming:parsed.incoming,kind:parsed.kind,contentRect:contentRect))
                } else if let hint = BubbleDescription.classify(description),
                          hint.incoming,
                          let childText = messageTextFromChildren(root,kind:hint.kind) {
                    // Captions are exposed as descendant AXStaticText nodes on some
                    // WhatsApp builds (especially image/video/file messages), while
                    // the cell description only contains the media label. Preserve
                    // that text so the same third action can translate the caption.
                    let contentRect = attachmentContentRect(root,cellRect:frame,kind:hint.kind)
                    bubbles.append(MessageBubble(text:childText,rect:frame,incoming:true,kind:hint.kind,contentRect:contentRect))
                } else {
                    // Keep an entry for every visible cell so the action disc can
                    // mirror WhatsApp's hover affordance even when the attachment
                    // has no caption or its AX description is not decodable.
                    let hint = BubbleDescription.classify(description)
                    let kind = hint?.kind ?? .other
                    let contentRect = attachmentContentRect(root,cellRect:frame,kind:kind)
                    bubbles.append(MessageBubble(text:"",rect:frame,incoming:hint?.incoming ?? false,kind:kind,contentRect:contentRect))
                }
            }
            return
        }
        guard let children = value(root,kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children { collectBubbles(child,into:&bubbles,budget:&budget,depth:depth+1) }
    }

    // A caption can be a child AXStaticText rather than part of the cell's
    // description. Read only text/value attributes from descendants and ignore
    // labels that simply repeat the media type. This is read-only and bounded so a
    // malformed accessibility tree cannot make hover scanning expensive.
    private func messageTextFromChildren(_ root: AXUIElement, kind: MessageContentKind) -> String? {
        var remaining = 80
        func walk(_ element: AXUIElement, depth: Int) -> String? {
            guard remaining > 0, depth < 8 else { return nil }
            remaining -= 1
            let role = string(element,kAXRoleAttribute)
            if role == "AXStaticText" || role == "AXTextField" || role == "AXTextArea" {
                for attribute in [kAXValueAttribute, kAXTitleAttribute] {
                    let candidate = string(element,attribute)
                        .filter { $0 != "\u{200E}" }
                        .trimmingCharacters(in:.whitespacesAndNewlines)
                    if candidate.count > 0 && candidate.count <= 20_000 && isCaption(candidate,kind:kind) {
                        return candidate
                    }
                }
            }
            guard let children = value(element,kAXChildrenAttribute) as? [AXUIElement] else { return nil }
            for child in children {
                if let found = walk(child,depth:depth+1) { return found }
            }
            return nil
        }
        // Do not consider the cell itself; its AXValue is often the same metadata
        // string that already failed parsing.
        guard let children = value(root,kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children {
            if let found = walk(child,depth:1) { return found }
        }
        return nil
    }

    private func isCaption(_ candidate: String, kind: MessageContentKind) -> Bool {
        let genericLabels = ["照片","视频","语音消息","语音","贴纸","GIF","动图","文件","文档","联系人","位置","实时位置","名片","音乐"]
        if genericLabels.contains(candidate) { return false }
        if candidate.contains("发来的") || candidate.contains("已发送到") || candidate.contains("已送达") { return false }
        if candidate.range(of:"^[\\d年月日时分秒:：\\s]+$",options:.regularExpression) != nil { return false }
        if candidate.range(of:"^(昨天|今天|前天|星期|周|上午|下午|中午|凌晨)\\s*[\\d:：\\s]*$",options:.regularExpression) != nil { return false }
        if kind == .file && candidate.range(of:"^[\\d.]+\\s*(B|KB|MB|GB|TB|字节|千字节|兆字节|吉字节)$",options:[.regularExpression,.caseInsensitive]) != nil { return false }
        return true
    }

    private func contentRect(_ root: AXUIElement, raw: String, body: String, cellRect: CGRect, kind: MessageContentKind) -> CGRect? {
        if let attachment = attachmentContentRect(root,cellRect:cellRect,kind:kind) {
            return attachment
        }
        if (kind == .file || kind == .media), let name = fileNameComponent(in:body) {
            return bodyBounds(root,raw:raw,body:name,cellRect:cellRect)
        }
        if kind == .link {
            return bodyBounds(root,raw:raw,body:body,cellRect:cellRect)
        }
        return nil
    }

    private func fileNameComponent(in body: String) -> String? {
        let components = body.components(separatedBy:", ")
            .map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return components.reversed().first(where: {
            $0.range(of:"^.+\\.[A-Za-z0-9]{1,10}$",options:.regularExpression) != nil
        })
    }


    // Bubble descriptions may contain U+200E direction marks that are not
    // included in the parsed body. Keep the AX range in the original UTF-16
    // coordinate space after matching against the cleaned text.
    private func rawRange(of body: String, in raw: String) -> NSRange? {
        let rawString = raw as NSString
        let direct = rawString.range(of: body)
        if direct.location != NSNotFound { return direct }

        let rawUnits = Array(raw.utf16)
        var cleanedUnits: [UInt16] = []
        var cleanedToRaw: [Int] = []
        cleanedUnits.reserveCapacity(rawUnits.count)
        cleanedToRaw.reserveCapacity(rawUnits.count)
        for (index, unit) in rawUnits.enumerated() where unit != 0x200E {
            cleanedToRaw.append(index)
            cleanedUnits.append(unit)
        }
        let cleaned = String(decoding: cleanedUnits, as: UTF16.self) as NSString
        let cleanedRange = cleaned.range(of: body)
        guard cleanedRange.location != NSNotFound else { return nil }
        let rawStart = cleanedToRaw[cleanedRange.location]
        let cleanedEnd = cleanedRange.location + cleanedRange.length
        let rawEnd = cleanedEnd < cleanedToRaw.count ? cleanedToRaw[cleanedEnd] : rawUnits.count
        return NSRange(location: rawStart, length: max(0, rawEnd - rawStart))
    }

    private func bodyBounds(_ element: AXUIElement, raw: String, body: String, cellRect: CGRect) -> CGRect? {
        guard let range = rawRange(of:body,in:raw), range.length > 0 else { return nil }
        var cfRange = CFRange(location:range.location,length:range.length)
        guard let parameter = AXValueCreate(.cfRange,&cfRange) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element,kAXBoundsForRangeParameterizedAttribute as CFString,parameter,&result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(result as! AXValue,.cgRect,&bounds), bounds.width > 0, bounds.height > 0,
              cellRect.intersects(bounds) else { return nil }
        return bounds
    }

    private func attachmentContentRect(_ root: AXUIElement, cellRect: CGRect, kind: MessageContentKind) -> CGRect? {
        guard kind == .media || kind == .file else { return nil }
        var remaining = 140
        var best: (rect: CGRect, area: CGFloat)?
        func walk(_ element: AXUIElement, depth: Int) {
            guard remaining > 0, depth < 10 else { return }
            remaining -= 1
            let role = string(element,kAXRoleAttribute)
            if let frame = rect(element), frame != cellRect,
               cellRect.contains(CGPoint(x:frame.midX,y:frame.midY)), frame.width > 12, frame.height > 12 {
                let ratio = frame.width * frame.height / max(1,cellRect.width * cellRect.height)
                let visualRole = role == "AXImage" || role == "AXLink" || role == "AXGroup" || role == "AXButton"
                // Prefer an explicit visual attachment node; groups are accepted for
                // document tiles whose filename and icon are wrapped together.
                if visualRole && ratio > 0.04 && ratio < 0.96 {
                    if best == nil || ratio > best!.area { best = (frame,ratio) }
                }
            }
            guard let children = value(element,kAXChildrenAttribute) as? [AXUIElement] else { return }
            for child in children { walk(child,depth:depth+1) }
        }
        guard let children = value(root,kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children { walk(child,depth:1) }
        return best?.rect
    }

    // Writes text into the composer of the given snapshot, only while it is still
    // the same element (chat not switched). Used for translation display/restore.
    @discardableResult
    func write(_ target: DraftSnapshot, text: String) -> Bool {
        guard let current = snapshot(requireFrontmost:false,allowEmpty:true), CFEqual(target.element,current.element) else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(current.element,kAXValueAttribute as CFString,&settable) == .success,
              settable.boolValue else { return false }
        guard AXUIElementSetAttributeValue(current.element,kAXValueAttribute as CFString,text as CFString) == .success else { return false }
        return true
    }

    // Diagnostic helper: writes the composer directly (no identity guards) and
    // reports whether WhatsApp accepted it.
    @discardableResult
    func writeComposer(_ text: String) -> Bool {
        guard let snap = snapshot(requireFrontmost:false) else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(snap.element,kAXValueAttribute as CFString,&settable) == .success,
              settable.boolValue else { return false }
        guard AXUIElementSetAttributeValue(snap.element,kAXValueAttribute as CFString,text as CFString) == .success else { return false }
        return true
    }

    func snapshot(requireFrontmost: Bool = true, allowEmpty: Bool = false) -> DraftSnapshot? {
        probe(requireFrontmost:requireFrontmost,allowEmpty:allowEmpty).snapshot
    }

    // MARK: - Message translation (read-only)

    // Prints every AX attribute of the message bubble cells so we can learn where the
    // visible text actually lives (kAXValueAttribute is empty on current builds).
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
