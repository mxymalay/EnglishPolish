import SwiftUI
import AppKit
import ApplicationServices

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
            let configuration = APIConfiguration(endpoint:endpoint,model:model,key:try SecretStore.read(endpoint))
            _ = try APIClient.makeRequest(text:source,configuration:configuration)
            let text = source; let token = generation
            busy = true
            requestTask = Task {
                do {
                    let response = try await APIClient().polish(text,configuration:configuration)
                    guard !Task.isCancelled, token == generation else { return }
                    result = response
                    selected = response.ambiguous ? nil : 0
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = PolishModel()
    var status: NSStatusItem!
    var overlay: FloatingPanel!
    var preview: NSWindow?
    var settings: NSWindow?
    var timer: Timer?
    var latest: DraftSnapshot?
    var paused = false
    var suspended = false
    var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        status = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName:"sparkles",accessibilityDescription:"轻语英文润色")
        let menu = NSMenu()
        menu.addItem(item("轻语 · 英文润色",action:nil))
        menu.addItem(.separator())
        menu.addItem(item("打开润色窗口",action:#selector(manual)))
        menu.addItem(item("设置…",action:#selector(showSettings)))
        menu.addItem(item("暂停浮动按钮",action:#selector(togglePause)))
        menu.addItem(.separator())
        menu.addItem(item("退出轻语",action:#selector(quit)))
        status.menu = menu
        overlay = FloatingPanel(contentRect:NSRect(x:0,y:0,width:32,height:32),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        overlay.isOpaque = false; overlay.backgroundColor = .clear; overlay.hasShadow = true
        overlay.level = .floating; overlay.hidesOnDeactivate = false
        overlay.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.transient]
        let button = NSButton(frame:NSRect(x:0,y:0,width:32,height:32))
        button.title = "✨"; button.font = .systemFont(ofSize:18); button.bezelStyle = .circular
        button.target = self; button.action = #selector(fromWhatsApp)
        button.toolTip = "润色这段英文"; button.setAccessibilityLabel("润色 WhatsApp 草稿")
        overlay.contentView = button
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] notification in
            let appID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in
                guard let self, self.preview?.isVisible == true, self.model.attached else { return }
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
    func tick() {
        guard !paused, !suspended, desktopReady(), (preview?.isVisible != true || !model.lease.valid),
              let draft = model.bridge.snapshot(),
              !draft.identity.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            overlay.orderOut(nil); latest = nil; return
        }
        latest = draft
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = NSPoint(x:draft.bounds.midX,y:primaryHeight-draft.bounds.midY)
        guard let screen = NSScreen.screens.first(where:{$0.frame.contains(point)}) else { overlay.orderOut(nil); return }
        overlay.setFrame(Placement.buttonRect(axRect:draft.bounds,primaryHeight:primaryHeight,visible:screen.visibleFrame),display:true)
        overlay.orderFrontRegardless()
    }
    @objc func fromWhatsApp() {
        guard desktopReady(), let draft = model.bridge.snapshot(), !draft.identity.text.isEmpty else { return }
        model.prepare(draft); showPreview(); model.generate()
    }
    @objc func manual() { model.prepare(nil); showPreview() }
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
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:562,height:670),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title = "轻语 · 设置"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView:SettingsView()); window.center(); settings = window
        }
        NSApp.activate(ignoringOtherApps:true); settings?.makeKeyAndOrderFront(nil)
    }
    @objc func togglePause(_ sender:NSMenuItem) {
        paused.toggle(); sender.title = paused ? "恢复浮动按钮" : "暂停浮动按钮"
        if paused { overlay.orderOut(nil) }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func windowWillClose(_ notification:Notification) {
        if let window = notification.object as? NSWindow, window === preview { model.cancel(); model.prepare(nil) }
    }
    func applicationWillTerminate(_ notification:Notification) { timer?.invalidate(); model.cancel() }
}

@main
struct EnglishPolishApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
