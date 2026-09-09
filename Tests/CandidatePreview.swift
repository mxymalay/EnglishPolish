import AppKit
import SwiftUI

// Local visual fixture: no WhatsApp access, no credentials, no network.
@MainActor
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    let model = PolishModel()
    let popover = NSPopover()
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        model.result = PolishResult(ambiguous:false, question:"", options:[
            Suggestion(english:"Could you send me the updated file when you have a moment?",chinese:"有空的时候能把更新后的文件发给我吗？"),
            Suggestion(english:"Please send me the updated file when you get a chance.",chinese:"方便时请把更新后的文件发给我。")
        ])
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:480,height:230),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "轻语 · 浮层外观测试"
        let anchor = NSHostingView(rootView:PolishTrigger { [weak self] in self?.show() })
        anchor.frame = NSRect(x:330,y:60,width:26,height:26)
        let content = NSView(frame:NSRect(x:0,y:0,width:480,height:230))
        content.addSubview(anchor)
        window.contentView = content
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView:CandidateView(model:model,
            choose:{ [weak self] _ in self?.popover.performClose(nil) },
            togglePin:{ [weak self] in
                guard let self else { return }
                self.model.pinned.toggle()
                self.popover.behavior = self.model.pinned ? .applicationDefined : .transient
            },
            close:{ [weak self] in self?.popover.performClose(nil) },settings:{}))
        DispatchQueue.main.async { [weak self] in self?.show() }
    }
    func show() {
        let anchor = window.contentView!.subviews[0]
        popover.show(relativeTo:anchor.bounds,of:anchor,preferredEdge:.minY)
    }
}
@main struct CandidatePreview {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = PreviewDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
