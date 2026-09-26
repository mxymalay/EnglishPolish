import SwiftUI
import AppKit
import ApplicationServices
import Combine

@MainActor
final class PolishModel: ObservableObject {
    @Published var source = ""
    @Published var result: PolishResult?
    @Published var selected: Int?
    @Published var busy = false
    @Published var message = ""
    @Published var attached = false
    @Published var completed = false
    @Published var lease = ReplacementLease()
    @Published var pinned = false
    var snapshot: DraftSnapshot?
    var requestTask: Task<Void,Never>?
    var generation = UUID()
    let bridge = WhatsAppBridge()

    var chosen: Suggestion? {
        guard let result, let selected, result.options.indices.contains(selected) else { return nil }
        return result.options[selected]
    }
    func prepare(_ draft: DraftSnapshot?) {
        cancel()
        snapshot = draft; attached = draft != nil
        source = draft?.identity.text ?? ""
        lease = ReplacementLease()
        pinned = false
        result = nil; selected = nil; message = ""; completed = false
    }
    func cancel() {
        generation = UUID(); requestTask?.cancel(); requestTask = nil; busy = false
    }
    func generate() {
        cancel(); result = nil; selected = nil; message = ""; completed = false
        do {
            let endpoint = UserDefaults.standard.string(forKey:"endpoint") ?? "https://api.openai.com/v1"
            let model = UserDefaults.standard.string(forKey:"model") ?? ""
            let casualPrompt = UserDefaults.standard.string(forKey:"casualPrompt") ?? APIClient.defaultCasualPrompt
            let formalPrompt = UserDefaults.standard.string(forKey:"formalPrompt") ?? APIClient.defaultFormalPrompt
            let configuration = APIConfiguration(endpoint:endpoint,model:model,key:try SecretStore.read(endpoint),casualPrompt:casualPrompt,formalPrompt:formalPrompt)
            _ = try APIClient.makeRequest(text:source,configuration:configuration)
            let text = source; let token = generation
            busy = true
            requestTask = Task {
                do {
                    let response = try await APIClient().polish(text,configuration:configuration)
                    guard !Task.isCancelled, token == generation else { return }
                    result = response
                    selected = response.ambiguous ? nil : 0
                    HistoryStore.shared.add(source:text,result:response)
                    busy = false
                } catch {
                    guard !Task.isCancelled, token == generation else { return }
                    busy = false
                    message = (error as? URLError)?.code == .timedOut ? "请求超时，请重试。原文仍然保留。" : error.localizedDescription
                }
            }
        } catch { message = error.localizedDescription }
    }
    func replace() {
        guard !completed, let snapshot, let chosen else { return }
        guard lease.valid else { message = "你已离开过预览窗口，请回到 WhatsApp 重新点击 ✨。也可以复制此结果。"; return }
        guard desktopReady() else { message = "桌面处于锁定或休眠状态，请恢复后重试。"; return }
        do {
            try bridge.replace(snapshot,with:chosen.english)
            message = "已替换，请回到 WhatsApp 检查后发送。"; completed = true
        } catch { message = error.localizedDescription }
    }
    func copy() {
        guard let chosen else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(chosen.english,forType:.string)
        message = "英文已复制。"
    }
}

func desktopReady() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String:Any],
          SessionPolicy.isReady(session) else { return false }
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0,nil,&count) == .success, count > 0 else { return false }
    var displays = [CGDirectDisplayID](repeating:0,count:Int(count))
    guard CGGetOnlineDisplayList(count,&displays,&count) == .success else { return false }
    return !displays.contains { CGDisplayIsAsleep($0) != 0 }
}

struct PolishView: View {
    @ObservedObject var model: PolishModel
    var openSettings: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Image(systemName:"sparkles").font(.title2).foregroundStyle(.teal)
                VStack(alignment:.leading,spacing:3) {
                    Text("把意思说清楚").font(.title2.bold())
                    Text(model.attached ? "WhatsApp · 先确认，再替换" : "粘贴英文，润色后复制使用").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action:openSettings) { Image(systemName:"gearshape") }.help("AI 设置")
            }
            Text("你的原文").font(.headline)
            if model.attached {
                ScrollView { Text(model.source).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(10) }
                    .frame(height:90).background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:10))
            } else {
                TextEditor(text:$model.source).font(.body).frame(height:90)
                    .padding(6).background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:10))
                    .disabled(model.busy)
                    .onChange(of:model.source) { _ in model.result = nil; model.selected = nil; model.completed = false }
            }
            HStack {
                Button(model.result == nil ? "✨ 润色英文" : "重新生成") { model.generate() }
                    .buttonStyle(.borderedProminent).tint(.teal).disabled(model.busy || model.source.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || model.completed)
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text("正在理解你的意思…").font(.callout).foregroundStyle(.secondary)
                    Button("取消") { model.cancel(); model.message = "已取消，原文未改动。" }
                }
            }
            Divider()
            if let result = model.result {
                if result.ambiguous {
                    Label(result.question,systemImage:"questionmark.bubble").font(.headline)
                    Text("原文可能有不同意思，请选你想表达的那一个。").font(.callout).foregroundStyle(.secondary)
                } else { Text("自然的英文").font(.headline) }
                ScrollView {
                    VStack(spacing:12) {
                        ForEach(Array(result.options.enumerated()),id:\.offset) { index,option in
                            VStack(alignment:.leading,spacing:10) {
                                if result.ambiguous {
                                    Button { model.selected = index } label: {
                                        Label(model.selected == index ? "已选择这个意思" : "选择这个意思",systemImage:model.selected == index ? "checkmark.circle.fill" : "circle")
                                    }.buttonStyle(.borderless).tint(.teal)
                                }
                                Text(option.english).font(.system(size:16)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                                Divider()
                                Text(option.chinese).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
                                .background(model.selected == index ? Color.teal.opacity(0.08) : Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:12))
                                .overlay(RoundedRectangle(cornerRadius:12).stroke(model.selected == index ? Color.teal.opacity(0.5) : Color.clear,lineWidth:1))
                        }
                    }
                }
                HStack {
                    if model.attached {
                        Button(model.completed ? "已替换" : "替换到 WhatsApp") { model.replace() }
                            .buttonStyle(.borderedProminent).tint(.teal).disabled(model.chosen == nil || model.completed || !model.lease.valid)
                    }
                    Button("复制英文") { model.copy() }.disabled(model.chosen == nil)
                    Spacer()
                }
            } else {
                VStack(spacing:12) {
                    Image(systemName:"text.bubble").font(.system(size:34)).foregroundStyle(.teal.opacity(0.65))
                    Text("自然一点，清楚一点。").font(.headline)
                    Text("润色结果和中文意思会显示在这里。").foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            if model.attached && !model.lease.valid {
                Text("离开预览后已停用替换。请回 WhatsApp 重新点击 ✨，或复制此结果。").font(.callout).foregroundStyle(.orange)
            }
            if !model.message.isEmpty {
                Text(model.message).font(.callout).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                    .padding(10).frame(maxWidth:.infinity,alignment:.leading).background(Color.orange.opacity(0.09),in:RoundedRectangle(cornerRadius:8))
            }
            Text("核对人名、数字和中文意思，确认后再发送。").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth:510,minHeight:610)
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// Translation-in-composer mode state; touched from the event-tap callback and the
// main app, both on the main thread.
final class TranslationDisplayState {
    var snapshot: DraftSnapshot?
    var original = ""
    var composerBounds: CGRect?
}

fileprivate let translationDisplayState = TranslationDisplayState()
fileprivate var tapBridge: WhatsAppBridge?
fileprivate var tapTranslator: TranslateModel?

fileprivate func keyTapCallback(_ proxy: CGEventTapProxy,_ type: CGEventType,_ event: CGEvent,_ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // While a translation is displayed in the composer, the first key restores the
    // original draft. Enter is swallowed so the translation is never sent by
    // accident; every other key lands in the restored draft.
    if type == .keyDown, let snap = translationDisplayState.snapshot {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        var restored = false
        if let bridge = tapBridge { restored = bridge.write(snap,text:translationDisplayState.original) }
        translationDisplayState.snapshot = nil
        translationDisplayState.original = ""
        translationDisplayState.composerBounds = nil
        Task { @MainActor in tapTranslator?.dismiss() }
        if restored && keyCode != 36 && keyCode != 76 { return Unmanaged.passUnretained(event) }
        return nil
    }
    return Unmanaged.passUnretained(event)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = PolishModel()
    var status: NSStatusItem!
    var statusMessage: NSMenuItem!
    var overlay: FloatingPanel!
    var candidates: FloatingPanel!
    var candidateHosting: NSHostingView<CandidatePanelView>!
    var candidateAnchor: CGRect?
    var candidateOpensBelow = true
    var candidateSizeObserver: AnyCancellable?
    let translator = TranslateModel()
    var translateObserver: AnyCancellable?
    let reason = ReasonModel()
    var reasonPanel: FloatingPanel?
    var reasonHosting: NSHostingView<ReasonPanelView>?
    var reasonAnchor: CGRect?
    var reasonOpensBelow = false
    var reasonRetry: (() -> Void)?
    /// 同一个失败原因只处理一次。phase 会一直是 .failed，而 objectWillChange
    /// 还会再触发几次，不加这个标记就会反复往输入框里写同一段文字。
    var displayedFailure: String?
    var escapeMonitor: Any?
    var reasonHideWork: DispatchWorkItem?
    var hoverButtonPanel: FloatingPanel?
    var hoverHosting: NSHostingView<HoverTranslateButton>?
    var keyEventTap: CFMachPort?
    var moveMonitor: Any?
    var visibleBubbles: [MessageBubble] = []
    var hoveredBubble: MessageBubble?
    var hoverButtonTarget: MessageBubble?
    var hoverButtonAnchor: CGRect?
    var hoverButtonFrame: CGRect?
    var hoverButtonEnabled: Bool?
    var hoverAnchorGeneration = 0
    var hoverAnchorRequestInFlight = false
    var translationAnchorFrame: CGRect?
    var translationOpenedAt: Date?
    var hoverTimer: Timer?
    var autoCandidateText = ""
    var autoCandidateCount = 0
    var autoCandidateToken = ""
    var preview: NSWindow?
    var settings: NSWindow?
    var timer: Timer?
    var latest: DraftSnapshot?
    var paused = false
    var suspended = false
    var observers: [NSObjectProtocol] = []
    var globalClickMonitor: Any?
    var localClickMonitor: Any?

    func makeCandidateView() -> CandidatePanelView {
        CandidatePanelView(model:model,opensBelow:candidateOpensBelow,
            choose:{ [weak self] index in
                guard let self else { return }
                self.model.selected = index
                self.model.replace()
                if self.model.completed {
                    // The composer now holds the polished text; never auto-polish it again.
                    self.autoCandidateToken = self.model.chosen?.english ?? ""
                    self.dismissCandidates()
                }
            },togglePin:{ [weak self] in self?.toggleCandidatePin() },
            close:{ [weak self] in self?.dismissCandidates() },
            settings:{ [weak self] in self?.dismissCandidates();self?.showSettings() })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        status = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName:"sparkles",accessibilityDescription:"轻语英文润色")
        let menu = NSMenu()
        statusMessage = item(FloatingButtonStatus.starting.menuTitle,action:nil)
        menu.addItem(statusMessage)
        menu.addItem(.separator())
        menu.addItem(item("打开润色窗口",action:#selector(manual)))
        menu.addItem(item("设置…",action:#selector(showSettings)))
        menu.addItem(item("暂停浮动按钮",action:#selector(togglePause)))
        menu.addItem(.separator())
        menu.addItem(item("退出轻语",action:#selector(quit)))
        status.menu = menu
        overlay = FloatingPanel(contentRect:NSRect(x:0,y:0,width:26,height:26),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        overlay.isOpaque = false; overlay.backgroundColor = .clear; overlay.hasShadow = true
        overlay.level = .floating; overlay.hidesOnDeactivate = false
        overlay.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.transient]
        overlay.contentView = NSHostingView(rootView:PolishTrigger { [weak self] in self?.fromWhatsApp() })
        candidateHosting = NSHostingView(rootView:makeCandidateView())
        candidates = FloatingPanel(contentRect:NSRect(x:0,y:0,width:374,height:150),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        candidates.isOpaque = false; candidates.backgroundColor = .clear; candidates.hasShadow = false
        candidates.level = .popUpMenu; candidates.hidesOnDeactivate = false
        candidates.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.transient]
        candidates.contentView = candidateHosting
        candidateSizeObserver = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizeCandidates() }
        }
        translateObserver = translator.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.presentTranslationInComposer() }
        }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.mouseMoved]) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTranslationDisplay()
                self?.updateHoverButton()
            }
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.scrollWheel]) { [weak self] event in
            Task { @MainActor in
                self?.closeUnpinnedCandidatesOutside()
                // Inside the composer = reading the translation; only leaving it
                // restores the draft. Clicks use the strict rect so they always land.
                let reading = self?.cursorInTranslationComposer(generous:event.type == .scrollWheel) ?? false
                if !reading { self?.restoreTranslationDisplay() }
                if event.type == .scrollWheel { self?.scrollRefresh() }
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.scrollWheel]) { [weak self] event in
            Task { @MainActor in
                self?.closeUnpinnedCandidatesOutside()
                if event.type == .scrollWheel { self?.scrollRefresh() }
            }
            return event
        }
        // Esc 是"关不掉"的兜底出口。两个浮层都收掉，不管当前是哪个、有没有被固定。
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                guard let self else { return }
                if self.reason.isShowing { self.hideReason() }
                if self.candidates.isVisible { self.dismissCandidates() }
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] notification in
            let appID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in
                guard let self, self.preview?.isVisible == true, self.model.attached, !self.model.pinned else { return }
                self.model.lease.observeActivation(isOwnApp:appID == Bundle.main.bundleIdentifier)
            }
        })
        for name in [NSWorkspace.screensDidSleepNotification,NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.suspended = true; self?.overlay.orderOut(nil); self?.latest = nil; self?.model.lease.observeActivation(isOwnApp:false) }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification,NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.suspended = false } })
        }
        timer = Timer.scheduledTimer(withTimeInterval:0.8,repeats:true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        hoverTimer = Timer.scheduledTimer(withTimeInterval:0.3,repeats:true) { [weak self] _ in Task { @MainActor in self?.updateHoverButton() } }
        tapBridge = model.bridge
        tapTranslator = translator
        let keyMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        if let tap = CGEvent.tapCreate(tap:.cghidEventTap,place:.headInsertEventTap,options:.defaultTap,
                                       eventsOfInterest:CGEventMask(keyMask),callback:keyTapCallback,userInfo:nil) {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0)
            CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes)
            CGEvent.tapEnable(tap:tap,enable:true)
            keyEventTap = tap
        }
        if !UserDefaults.standard.bool(forKey:"onboarded") || (UserDefaults.standard.string(forKey:"model") ?? "").isEmpty || !AXIsProcessTrusted() {
            if desktopReady() { showSettings(); UserDefaults.standard.set(true,forKey:"onboarded") }
        }
    }
    func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        let newItem = NSMenuItem(title:"打开润色窗口",action:#selector(manual),keyEquivalent:"n"); newItem.target = self
        appMenu.addItem(newItem)
        let settingsItem = NSMenuItem(title:"设置…",action:#selector(showSettings),keyEquivalent:","); settingsItem.target = self
        appMenu.addItem(settingsItem); appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title:"退出轻语",action:#selector(quit),keyEquivalent:"q"); quitItem.target = self
        appMenu.addItem(quitItem); appItem.submenu = appMenu; main.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title:"编辑")
        for (title,action,key) in [("撤销","undo:","z"),("剪切","cut:","x"),("复制","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")] {
            edit.addItem(NSMenuItem(title:title,action:Selector(action),keyEquivalent:key))
        }
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool {
        if !hasVisibleWindows && desktopReady() { showSettings() }
        return true
    }
    func item(_ title: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; return item
    }
    func updateFloatingStatus(_ status: FloatingButtonStatus) {
        statusMessage?.title = status.menuTitle
    }
    func tick() {
        refreshVisibleBubbles()
        // 原因气泡跟着 WhatsApp 走：离开 WhatsApp、暂停、锁屏都收起来，避免它挂在
        // 桌面上没人管。
        if reasonPanel?.isVisible == true {
            let active = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if paused || suspended || !desktopReady()
                || (active != WhatsAppBridge.bundleID && active != Bundle.main.bundleIdentifier) {
                hideReason()
            }
        }
        if candidates.isVisible {
            if model.pinned { return }
            let active = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            guard !paused, !suspended, desktopReady(),
                  active == WhatsAppBridge.bundleID || active == Bundle.main.bundleIdentifier,
                  let original = model.snapshot, let current = model.bridge.snapshot(requireFrontmost:false),
                  original.identity.mayReplace(with:current.identity),
                  CFEqual(original.element,current.element), CFEqual(original.header,current.header),
                  original.bounds == current.bounds, original.composerBounds == current.composerBounds else {
                dismissCandidates()
                return
            }
            return
        }
        guard !paused else { updateFloatingStatus(.paused); overlay.orderOut(nil); latest = nil; return }
        guard !suspended, desktopReady() else { updateFloatingStatus(.desktopUnavailable); overlay.orderOut(nil); latest = nil; return }
        guard preview?.isVisible != true || !model.lease.valid else { updateFloatingStatus(.previewOpen); overlay.orderOut(nil); latest = nil; return }
        // The composer currently shows a message translation; keep the polish flows
        // out of the way until the original draft is restored.
        guard translationDisplayState.snapshot == nil else { overlay.orderOut(nil); latest = nil; return }
        let probe = model.bridge.probe()
        updateFloatingStatus(probe.status)
        guard let draft = probe.snapshot else { overlay.orderOut(nil); latest = nil; return }
        latest = draft
        autoCandidatesTick(draft)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = NSPoint(x:draft.bounds.midX,y:primaryHeight-draft.bounds.midY)
        guard let screen = NSScreen.screens.first(where:{$0.frame.contains(point)}) else { overlay.orderOut(nil); return }
        overlay.setFrame(Placement.buttonRect(axRect:draft.bounds,composerRect:draft.composerBounds,sendRect:draft.sendBounds,primaryHeight:primaryHeight,visible:screen.visibleFrame),display:true)
        overlay.orderFrontRegardless()
    }
    @objc func fromWhatsApp() {
        if candidates.isVisible { dismissCandidates(); return }
        hideReason()
        guard desktopReady() else {
            showReason(AIReason(title:"桌面暂不可用",message:"屏幕处于锁定或休眠状态，恢复后再点 ✨。",retryable:false))
            return
        }
        guard let draft = model.bridge.snapshot(), !draft.identity.text.isEmpty else {
            // 点了 ✨ 却读不到草稿时也要说一声，不能什么都不显示。
            showReason(AIReason(title:"没读到草稿",message:"读不到 WhatsApp 输入框里的内容。请先点一下输入框、写下英文，再点 ✨。",hint:"浮动按钮只跟随当前聊天的输入框。",retryable:false))
            return
        }
        preview?.orderOut(nil)
        model.prepare(draft)
        model.generate()
        candidateAnchor = overlay.frame
        // The trigger lives above the send button, so a downward panel would cover the
        // composer and the send button itself; open into the message area by default.
        // resizeCandidates flips downward only when there is no room above.
        candidateOpensBelow = false
        candidateHosting.rootView = makeCandidateView()
        resizeCandidates()
        candidates.orderFrontRegardless()
    }
    func toggleCandidatePin() {
        model.pinned.toggle()
    }
    func resizeCandidates() {
        guard let anchor=candidateAnchor,
              let screen=NSScreen.screens.first(where:{$0.frame.intersects(anchor)}) else { return }
        candidateHosting.layoutSubtreeIfNeeded()
        var fitting=candidateHosting.fittingSize
        let visible=screen.visibleFrame
        let primaryHeight=NSScreen.screens.first?.frame.height ?? 0
        // AppKit y of the composer's top edge; upward panels anchor here so the
        // draft text the user is editing always stays visible.
        let composerTopAK=primaryHeight-(latest?.composerBounds.minY ?? anchor.maxY)
        // Long candidates can outgrow the side chosen when the panel was still a small
        // "正在润色…" stub; flip before placing it.
        let spaceBelow=anchor.minY-visible.minY-8, spaceAbove=composerTopAK-visible.minY-8
        func flip(to below: Bool) {
            candidateOpensBelow=below
            candidateHosting.rootView=makeCandidateView()
            candidateHosting.layoutSubtreeIfNeeded()
            fitting=candidateHosting.fittingSize
        }
        if candidateOpensBelow && fitting.height > spaceBelow && spaceAbove >= fitting.height { flip(to:false) }
        else if !candidateOpensBelow && fitting.height > spaceAbove && spaceBelow >= fitting.height { flip(to:true) }
        let content=CGSize(width:max(374,fitting.width),height:max(82,fitting.height))
        let frame: CGRect
        if candidateOpensBelow {
            frame=Placement.candidateRect(anchor:anchor,contentSize:content,visible:visible,opensBelow:true)
        } else {
            // Anchor the panel bottom at the composer top, centered on the composer.
            let composer=latest?.composerBounds
            let midX=composer?.midX ?? anchor.midX
            let pseudo=CGRect(x:midX-13,y:0,width:26,height:max(0,composerTopAK-2))
            frame=Placement.candidateRect(anchor:pseudo,contentSize:content,visible:visible,opensBelow:false)
        }
        candidates.setFrame(frame,display:true)
    }
    // MARK: - 原因气泡

    // 任何一次 AI 失败都要落到一个看得见的气泡上：锚在 WhatsApp 输入框旁，和候选
    // 气泡同一套外观。只写菜单栏等于没写——用户在看 WhatsApp，菜单栏标题要展开
    // 才看得到，结果就是「点了没反应」。
    func makeReasonView() -> ReasonPanelView {
        ReasonPanelView(model:reason,opensBelow:reasonOpensBelow,
            retry:{ [weak self] in self?.retryReason() },
            settings:{ [weak self] in self?.hideReason();self?.showSettings() },
            close:{ [weak self] in self?.hideReason() })
    }

    func makeReasonPanel() -> FloatingPanel {
        let panel = FloatingPanel(contentRect:NSRect(x:0,y:0,width:354,height:150),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .popUpMenu; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.transient]
        reasonHosting = NSHostingView(rootView:makeReasonView())
        panel.contentView = reasonHosting
        return panel
    }

    // 浮层的显示/隐藏各记一行，出问题时有据可查。没有日志就只能靠猜。
    func logPanel(_ event: String) {
        let url = URL(fileURLWithPath:"/tmp/lightu-panels.log")
        let line = "\(ISO8601DateFormatter().string(from:Date())) \(event)\n"
        if let handle = try? FileHandle(forWritingTo:url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(to:url,atomically:true,encoding:.utf8)
        }
    }

    func showReason(_ reason: AIReason, retry: (() -> Void)? = nil) {
        // 原因气泡和候选气泡都挂在输入框上方。同时出现会互相压住，也分不清点的是哪个，
        // 表现成"关不掉"。所以显示一个就把另一个收掉。
        if candidates.isVisible { dismissCandidates() }
        self.reason.show(reason)
        reasonRetry = retry
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let composer = model.bridge.snapshot(requireFrontmost:false,allowEmpty:true)?.composerBounds ?? latest?.composerBounds
        reasonAnchor = composer.map { appKitRect($0,primaryHeight:primaryHeight) }
            ?? CGRect(origin:NSEvent.mouseLocation,size:.zero)
        reasonOpensBelow = false
        if reasonPanel == nil { reasonPanel = makeReasonPanel() }
        reasonHosting?.rootView = makeReasonView()
        reasonHosting?.layoutSubtreeIfNeeded()
        reasonPanel?.setFrame(reasonFrame(),display:true)
        reasonPanel?.orderFrontRegardless()
        logPanel("show reason: \(reason.title) | anchor=\(reasonAnchor ?? .zero) | frame=\(reasonPanel?.frame ?? .zero)")
        // 兜底：这个气泡不能变成关不掉的障碍物。到时自动收掉，原因在别处也还看得到。
        reasonHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.reason.isShowing else { return }
            self.logPanel("auto-hide reason after timeout")
            self.hideReason()
        }
        reasonHideWork = work
        DispatchQueue.main.asyncAfter(deadline:.now()+25,execute:work)
    }

    func reasonFrame() -> CGRect {
        let anchor = reasonAnchor ?? CGRect(origin:NSEvent.mouseLocation,size:.zero)
        let visible = NSScreen.screens.first(where:{$0.frame.intersects(anchor)})?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x:0,y:0,width:1200,height:800)
        let fitting = reasonHosting?.fittingSize ?? CGSize(width:354,height:150)
        let content = CGSize(width:max(354,fitting.width),height:max(64,fitting.height))
        let spaceBelow = anchor.minY - visible.minY - 8
        let spaceAbove = visible.maxY - anchor.maxY - 8
        // 默认往上展开，别盖住用户正在看的输入框；上面放不下再翻到下面。
        let below = reasonOpensBelow
            ? !(content.height > spaceBelow && spaceAbove >= content.height)
            : (content.height > spaceAbove && spaceBelow >= content.height)
        if below != reasonOpensBelow {
            reasonOpensBelow = below
            reasonHosting?.rootView = makeReasonView()
            reasonHosting?.layoutSubtreeIfNeeded()
        }
        let size = CGSize(width:max(354,reasonHosting?.fittingSize.width ?? 0),height:max(64,reasonHosting?.fittingSize.height ?? 0))
        return Placement.candidateRect(anchor:anchor,contentSize:size,visible:visible,opensBelow:reasonOpensBelow)
    }

    func hideReason() {
        reasonHideWork?.cancel(); reasonHideWork = nil
        if reasonPanel?.isVisible == true { logPanel("hide reason") }
        reasonPanel?.orderOut(nil)
        reasonAnchor = nil
        reasonRetry = nil
        reason.clear()
    }

    func retryReason() {
        let action = reasonRetry
        hideReason()
        action?()
    }

    // Optional auto mode: once the draft stops changing, open the candidate panel
    // without waiting for the ✨ click. A token prevents re-opening for text the user
    // dismissed or already replaced.
    func autoCandidatesTick(_ draft: DraftSnapshot) {
        guard UserDefaults.standard.bool(forKey:"autoShowCandidates"), !candidates.isVisible,
              preview?.isVisible != true else { return }
        if draft.identity.text == autoCandidateText { autoCandidateCount += 1 }
        else { autoCandidateText = draft.identity.text; autoCandidateCount = 1 }
        guard autoCandidateCount >= 3, autoCandidateToken != draft.identity.text else { return }
        autoCandidateToken = draft.identity.text
        fromWhatsApp()
    }

    func closeUnpinnedCandidatesOutside() {
        if reasonPanel?.isVisible == true, let frame = reasonPanel?.frame, !frame.contains(NSEvent.mouseLocation) {
            hideReason()
        }
        guard candidates.isVisible, !model.pinned else { return }
        let point = NSEvent.mouseLocation
        guard !candidates.frame.contains(point), !overlay.frame.contains(point) else { return }
        dismissCandidates()
    }

    // MARK: - Hover translation

    // Scrolling invalidates cached bubble rects immediately: resync and hide the
    // hover button so it never anchors to a pre-scroll position.
    func scrollRefresh() {
        guard !visibleBubbles.isEmpty || hoverButtonPanel?.isVisible == true else { return }
        hideHoverButton()
        refreshVisibleBubbles()
    }

    func refreshVisibleBubbles() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard UserDefaults.standard.bool(forKey:"hoverTranslateEnabled") else {
            visibleBubbles = []; hideHoverButton(); return
        }
        guard !paused, !suspended, desktopReady(), frontmost == WhatsAppBridge.bundleID else {
            visibleBubbles = []; hideHoverButton(); return
        }
        visibleBubbles = model.bridge.scanMessages()
        updateHoverButton()
    }

    private func appKitRect(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x:rect.minX,y:primaryHeight-rect.maxY,width:rect.width,height:rect.height)
    }

    private func appKitRect(_ bubble: MessageBubble, primaryHeight: CGFloat) -> CGRect {
        appKitRect(bubble.rect, primaryHeight: primaryHeight)
    }

    // Cursor hit-test against the last scan; runs on its own 0.3 s timer so the
    // button follows the pointer without extra accessibility walks.
    func updateHoverButton() {
        refreshTranslationDisplay()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        guard !visibleBubbles.isEmpty, !paused, !suspended, desktopReady(),
              front == WhatsAppBridge.bundleID else {
            hideHoverButton(); return
        }
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // While heading for an enabled button (crossing WhatsApp's emoji button),
        // keep it anchored; disabled ones vanish crisply with the hover.
        if let anchor = hoverButtonTarget, hoverButtonPanel?.isVisible == true,
           let frame = hoverButtonFrame, hoverButtonEnabled == true {
            let ak = appKitRect(hoverButtonAnchor ?? anchor.actionRect,primaryHeight:primaryHeight)
            let buttonZone = frame.insetBy(dx:-10,dy:-10)
            let corridor: CGRect
            if frame.minX >= ak.maxX {
                corridor = CGRect(x:ak.maxX,y:ak.midY - 30,width:frame.minX - ak.maxX,height:60)
            } else {
                corridor = CGRect(x:frame.maxX,y:ak.midY - 30,width:ak.minX - frame.maxX,height:60)
            }
            if buttonZone.contains(mouse) || corridor.contains(mouse) {
                return
            }
        }
        guard let hit = visibleBubbles.first(where:{ appKitRect($0,primaryHeight:primaryHeight).insetBy(dx:-6,dy:-4).contains(mouse) }) else {
            hideHoverButton(); return
        }
        // Media and file cells can expose a caption as AX text, but the user asked
        // for no translation affordance on any attached photo/video/document/file.
        guard hit.canTranslate else {
            hideHoverButton(); return
        }
        let translatable = hit.canTranslate
        if let current = hoverButtonTarget, current == hit, hoverButtonPanel?.isVisible == true {
            // WhatsApp may expose its hover layer one timer tick after the
            // message cell. Retry the real AX hit-test before keeping a fallback
            // anchor so the button never settles on a guessed vertical position.
            if hoverButtonAnchor == nil { requestNativeHoverAnchor(for:hit) }
            // Same bubble: flip between disabled and enabled without touching frames.
            if hoverButtonEnabled != translatable {
                hoverButtonEnabled = translatable
                hoverHosting?.rootView = HoverTranslateButton(model:translator,text:hit.text,enabled:translatable,action:{ [weak self] in self?.translateHovered() })
            }
            return
        }
        let bubbleAK = appKitRect(hit.rect,primaryHeight:primaryHeight)
        // WhatsApp's own hover controls live in a separate layer and can take a
        // noticeable amount of time to answer AX hit tests. Put our button on the
        // message action rect immediately, then read the native layer off the main
        // thread and replace the frame when it becomes available.
        hoveredBubble = translatable ? hit : nil
        hoverButtonTarget = hit
        hoverButtonEnabled = translatable
        hoverButtonAnchor = nil
        let actionAK = appKitRect(hit.actionRect,primaryHeight:primaryHeight)
        // Pure text follows WhatsApp's share action, so lightu occupies slot two.
        // Shared links and every attachment reserve both system actions and use
        // slot three. At the screen edge the group mirrors.
        let visible = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x:0,y:0,width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        let systemActionCount = hit.kind == .text ? 1 : 2
        let frame = MessageHoverPlacement.buttonRect(bubble:bubbleAK,visible:visible,systemActionCount:systemActionCount,verticalAnchor:actionAK)
        let panel = hoverButtonPanel ?? makeHoverButtonPanel()
        hoverButtonPanel = panel
        hoverButtonFrame = frame
        hoverHosting?.rootView = HoverTranslateButton(model:translator,text:hit.text,enabled:translatable,action:{ [weak self] in self?.translateHovered() })
        panel.setFrame(frame,display:true)
        panel.orderFrontRegardless()
        requestNativeHoverAnchor(for:hit)
    }

    private func requestNativeHoverAnchor(for hit: MessageBubble) {
        guard hoverButtonAnchor == nil, !hoverAnchorRequestInFlight else { return }
        let generation = hoverAnchorGeneration
        hoverAnchorRequestInFlight = true
        let bridge = model.bridge
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let discovered = bridge.hoverActionAnchor(near:hit.rect)
            DispatchQueue.main.async {
                guard let self else { return }
                self.hoverAnchorRequestInFlight = false
                guard self.hoverAnchorGeneration == generation,
                      self.hoverButtonTarget == hit,
                      self.hoverButtonPanel?.isVisible == true,
                      let discovered else { return }
                self.hoverButtonAnchor = discovered
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                let mouse = NSEvent.mouseLocation
                let visible = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.visibleFrame
                    ?? NSScreen.main?.visibleFrame
                    ?? CGRect(x:0,y:0,width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
                let actionAK = self.appKitRect(discovered,primaryHeight:primaryHeight)
                let bubbleAK = self.appKitRect(hit.rect,primaryHeight:primaryHeight)
                let systemActionCount = hit.kind == .text ? 1 : 2
                let frame = MessageHoverPlacement.buttonRect(bubble:bubbleAK,visible:visible,systemActionCount:systemActionCount,verticalAnchor:actionAK)
                self.hoverButtonFrame = frame
                self.hoverButtonPanel?.setFrame(frame,display:true)
            }
        }
    }

    func makeHoverButtonPanel() -> FloatingPanel {
        let panel = FloatingPanel(contentRect:NSRect(x:0,y:0,width:32,height:32),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.transient]
        hoverHosting = NSHostingView(rootView:HoverTranslateButton(model:translator,text:"",enabled:false,action:{ [weak self] in self?.translateHovered() }))
        panel.contentView = hoverHosting
        return panel
    }

    func hideHoverButton() {
        hoverAnchorGeneration += 1
        hoverButtonPanel?.orderOut(nil)
        hoverButtonFrame = nil
        hoveredBubble = nil
        hoverButtonTarget = nil
        hoverButtonAnchor = nil
        hoverButtonEnabled = nil
    }

    func translateHovered() {
        guard let bubble = hoveredBubble else { return }
        hideReason()
        translationAnchorFrame = hoverButtonPanel?.frame
        // Re-scan so the bubble anchors to the message's current position even if the
        // list scrolled since the last periodic scan.
        let fresh = model.bridge.scanMessages().first(where:{ $0.text == bubble.text }) ?? bubble
        translator.show(fresh)
        hideHoverButton()
    }

    // Writes the finished translation into the composer, remembering the draft it
    // replaced so any interaction afterwards restores it.
    func presentTranslationInComposer() {
        if case .failed(let error) = translator.phase {
            guard displayedFailure != error else { return }
            displayedFailure = error
            // 原因跟译文走同一条路写进输入框。写进去了就不再弹气泡——输入框里已经
            // 有，再弹一个就是同一件事说两遍。只有写不进去才退回气泡，否则真的一声
            // 不吭。不调 translator.dismiss()：failedBubble 要留着给重试用。
            if displayInComposer("【翻译失败】\(error)") {
                hideReason()
            } else {
                showReason(AIReason(title:"翻译失败",message:error,
                                    hint:"读不到 WhatsApp 的输入框，只能在这里显示原因。"),
                           retry:{ [weak self] in self?.translator.retry() })
            }
            hideHoverButton()
            return
        }
        // 回到非失败态就清掉标记，下一次失败能重新提示。
        displayedFailure = nil
        guard let translation = translator.doneText, translator.target != nil else { return }
        if displayInComposer(translation) {
            hideReason()
        } else {
            // 写不进去同样要说清楚，并把译文留在剪贴板，别让用户白等一次。
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(translation,forType:.string)
            showReason(AIReason(title:"没能写进输入框",message:"读不到或写不进 WhatsApp 的输入框，请先点一下聊天输入框再重试。",hint:"译文已复制到剪贴板，可以直接粘贴。",retryable:false))
        }
        // Delivered: clear the target so the hover button can appear again.
        translator.dismiss()
        hideHoverButton()
    }

    /// 把一段文字临时写进 WhatsApp 输入框。译文和失败原因共用这一条路，行为完全一致：
    /// 记住被替换掉的草稿，指针离开输入框、超过 12 秒、或按下任意键都会还原，
    /// 回车被事件拦截吞掉，不会被误发出去。返回是否真的写成功。
    @discardableResult
    func displayInComposer(_ text: String) -> Bool {
        if translationDisplayState.snapshot == nil {
            // The composer may be empty; the original (possibly "") is what gets restored.
            guard let snap = model.bridge.snapshot(requireFrontmost:false,allowEmpty:true) else { return false }
            translationDisplayState.snapshot = snap
            translationDisplayState.original = snap.identity.text
        }
        guard model.bridge.write(translationDisplayState.snapshot!,text:text) else {
            translationDisplayState.snapshot = nil
            translationDisplayState.original = ""
            translationDisplayState.composerBounds = nil
            return false
        }
        translationDisplayState.composerBounds = nil
        translationOpenedAt = Date()
        // The composer grows once the text lands; re-measure it shortly after so
        // hit-testing matches the grown field.
        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline:.now()+delay) { [weak self] in
                guard let self, translationDisplayState.snapshot != nil else { return }
                translationDisplayState.composerBounds = self.model.bridge.snapshot(requireFrontmost:false,allowEmpty:true)?.composerBounds
            }
        }
        return true
    }

    // True while the pointer hovers the composer showing a translation. `generous`
    // covers scroll-reading: before the re-measurement lands, accept the column the
    // composer will grow into; afterwards both paths use the real grown rect.
    func cursorInTranslationComposer(generous: Bool) -> Bool {
        guard let composer = translationDisplayState.composerBounds ?? translationDisplayState.snapshot?.composerBounds else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ak = CGRect(x:composer.minX,y:primaryHeight-composer.maxY,width:composer.width,height:composer.height)
        if generous {
            let band = CGRect(x:ak.minX - 12,y:ak.minY - 12,width:ak.width + 24,height:ak.height + 480)
            return band.contains(NSEvent.mouseLocation)
        }
        return ak.insetBy(dx:-6,dy:-6).contains(NSEvent.mouseLocation)
    }

    // A hover translation is a temporary reading view. Restore the user's draft
    // after the pointer leaves the composer, and always recover after a bounded
    // interval even when no mouse event is delivered (for example after switching
    // spaces or activating another app).
    func refreshTranslationDisplay() {
        guard translationDisplayState.snapshot != nil else { return }
        let opened = translationOpenedAt ?? Date()
        if translationOpenedAt == nil { translationOpenedAt = opened }
        let age = Date().timeIntervalSince(opened)
        if age >= 12 || (age >= 0.8 && !cursorInTranslationComposer(generous:true)) {
            restoreTranslationDisplay()
        }
    }

    func restoreTranslationDisplay() {
        guard let snap = translationDisplayState.snapshot else { return }
        _ = tapBridge?.write(snap,text:translationDisplayState.original)
        translationDisplayState.snapshot = nil
        translationDisplayState.original = ""
        translationDisplayState.composerBounds = nil
        translationOpenedAt = nil
        translationAnchorFrame = nil
        translator.dismiss()
    }

        func dismissCandidates() {
        guard candidates.isVisible || candidateAnchor != nil else { return }
        if candidates.isVisible { logPanel("dismiss candidates") }
        candidates.orderOut(nil)
        candidateAnchor=nil
        if let dismissed = model.snapshot?.identity.text { autoCandidateToken = dismissed }
        model.cancel()
        model.prepare(nil)
        latest = nil
    }
    @objc func manual() { dismissCandidates(); model.prepare(nil); showPreview() }
    func showPreview() {
        overlay.orderOut(nil)
        if preview == nil {
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:560,height:680),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.title = "轻语 · 英文润色"; window.isReleasedWhenClosed = false
            window.minSize = NSSize(width:550,height:650); window.delegate = self
            window.contentView = NSHostingView(rootView:PolishView(model:model,openSettings:{ [weak self] in self?.showSettings() }))
            preview = window; window.center()
        }
        NSApp.activate(ignoringOtherApps:true); preview?.makeKeyAndOrderFront(nil)
    }
    @objc func showSettings() {
        if settings == nil {
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:660,height:600),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.title = "轻语 · 设置"; window.isReleasedWhenClosed = false
            window.minSize = NSSize(width:620,height:520)
            window.contentView = NSHostingView(rootView:SettingsView(history:HistoryStore.shared)); window.center(); settings = window
        }
        NSApp.activate(ignoringOtherApps:true); settings?.makeKeyAndOrderFront(nil)
    }
    @objc func togglePause(_ sender:NSMenuItem) {
        paused.toggle(); sender.title = paused ? "恢复浮动按钮" : "暂停浮动按钮"
        if paused { overlay.orderOut(nil); updateFloatingStatus(.paused) }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func windowWillClose(_ notification:Notification) {
        if let window = notification.object as? NSWindow, window === preview { model.cancel(); model.prepare(nil) }
    }
    func applicationWillTerminate(_ notification:Notification) {
        timer?.invalidate(); hoverTimer?.invalidate(); model.cancel()
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }
}

#if !CANDIDATE_PREVIEW
@main
struct EnglishPolishApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--dump-bubbles") {
            let bridge = WhatsAppBridge()
            for bubble in bridge.scanMessages() {
                print("kind=\(bubble.kind) incoming=\(bubble.incoming) canTranslate=\(bubble.canTranslate) rect=\(bubble.rect) contentRect=\(bubble.contentRect.map(String.init(describing:)) ?? "nil") text=\(bubble.text)")
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--dump-hover") {
            let bridge = WhatsAppBridge()
            var report = ""
            for tick in 0..<10 {
                if tick >= 2 && tick <= 5 {
                    // Jiggle the pointer over a link/media bubble to force WhatsApp's
                    // own hover actions into the accessibility tree.
                    let target = bridge.scanMessages().first(where: { $0.text.contains("http") || $0.text.contains("链接") }) ?? bridge.scanMessages().first
                    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                    let point = target.map { CGPoint(x:$0.rect.midX,y:primaryHeight-$0.rect.midY) } ?? CGPoint(x:660,y:537)
                    let jiggle: [CGPoint] = [point,CGPoint(x:point.x+3,y:point.y+3),CGPoint(x:point.x-2,y:point.y-1),point]
                    if let move = CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:jiggle[tick-2],mouseButton:.left) {
                        move.post(tap:.cghidEventTap)
                    }
                }
                report += "\n===== t=\(tick)s =====\n"
                report += bridge.dumpMessageButtons() ?? "无法读取"
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                report += "\n-- screens: \(NSScreen.screens.map { "primary=\(NSScreen.screens.first === $0) \($0.frame) visible=\($0.visibleFrame)" }.joined(separator:" | ")) primaryHeight=\(primaryHeight)"
                for bubble in bridge.scanMessages() {
                    let ak = CGRect(x:bubble.rect.minX,y:primaryHeight-bubble.rect.maxY,width:bubble.rect.width,height:bubble.rect.height)
                    let height: CGFloat = 120
                    guard let screen = NSScreen.screens.first(where:{$0.visibleFrame.intersects(ak)}) else { report += "\n[bubble offscreen] \(bubble.rect)"; continue }
                    let topEdge = min(max(ak.maxY,screen.visibleFrame.minY + 6 + height),screen.visibleFrame.maxY - 6)
                    report += "\n[bubble] ax=\(bubble.rect) akTop=\(ak.maxY) topEdge=\(topEdge) panelY=\(topEdge-height)"
                }
                try? report.write(to:URL(fileURLWithPath:"/tmp/lightu-hover.txt"),atomically:true,encoding:.utf8)
                let deadline = Date().addingTimeInterval(1)
                while Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
            }
            print("done")
            exit(0)
        }
        if CommandLine.arguments.contains("--dump-composer") {
            let bridge = WhatsAppBridge()
            var report = bridge.dumpComposerButtons() ?? "无法读取"
            if let snap = bridge.snapshot(requireFrontmost:false) {
                report += "\nsendBounds=\(snap.sendBounds.map(String.init(describing:)) ?? "nil")"
                let original = snap.identity.text
                let long = Array(repeating:"What are you doing? we are going to the internet, do you want to go with us? its ok if u don't come, we are fine, really.",count:2).joined(separator:" ")
                if bridge.writeComposer(long) {
                    let deadline = Date().addingTimeInterval(1.5)
                    while Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.1)) }
                    report += "\n\n=== 长草稿状态 ===\n"
                    report += bridge.dumpComposerButtons() ?? ""
                    if let after = bridge.snapshot(requireFrontmost:false) {
                        report += "\nsendBounds=\(after.sendBounds.map(String.init(describing:)) ?? "nil")"
                    }
                    _ = bridge.writeComposer(original)
                } else {
                    report += "\n无法写入长草稿"
                }
            }
            try? report.write(to:URL(fileURLWithPath:"/tmp/lightu-composer.txt"),atomically:true,encoding:.utf8)
            print(report)
            exit(0)
        }
        if CommandLine.arguments.contains("--simulate-hover") {
            // Self-test: hover a real incoming bubble, click our translate button, then
            // keep running normally so the UI under test stays alive.
            let bridge = WhatsAppBridge()
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval:1.5)
                NSRunningApplication.runningApplications(withBundleIdentifier:WhatsAppBridge.bundleID).first?.activate()
                Thread.sleep(forTimeInterval:0.8)
                guard let bubble = bridge.scanMessages().first else {
                    try? "no bubble".write(to:URL(fileURLWithPath:"/tmp/lightu-sim.txt"),atomically:true,encoding:.utf8)
                    return
                }
                func move(_ point: CGPoint) {
                    if let e = CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:point,mouseButton:.left) { e.post(tap:.cghidEventTap) }
                }
                func click(_ point: CGPoint) {
                    if let down = CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left) { down.post(tap:.cghidEventTap) }
                    usleep(80_000)
                    if let up = CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left) { up.post(tap:.cghidEventTap) }
                }
                let center = CGPoint(x:bubble.rect.midX,y:bubble.rect.midY)
                click(center); Thread.sleep(forTimeInterval:0.8)
                move(center); Thread.sleep(forTimeInterval:1.5)
                let button = CGPoint(x:bubble.rect.maxX + 48 + 16,y:bubble.rect.midY)
                move(CGPoint(x:button.x - 10,y:button.y)); Thread.sleep(forTimeInterval:0.5)
                click(button)
                Thread.sleep(forTimeInterval:4.0)
                let log = (try? String(contentsOfFile:"/tmp/lightu-debug.log",encoding:.utf8)) ?? "(no log)"
                try? ("=== LOG ===\n\(log)").write(to:URL(fileURLWithPath:"/tmp/lightu-sim.txt"),atomically:true,encoding:.utf8)
            }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
