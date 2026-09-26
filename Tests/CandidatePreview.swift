import AppKit
import SwiftUI

// Local visual fixture: no WhatsApp access, no credentials, no network.
@MainActor
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    let model = PolishModel()
    let reason = ReasonModel()
    let popover = NSPopover()
    var window: NSWindow!
    var reasonWindow: NSWindow!
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
        showReasonFixture()
        DispatchQueue.main.async { [weak self] in self?.show() }
    }
    // 失败路径的版式：本地 AI 不可用时，原因要落在输入框旁的气泡里。
    func showReasonFixture() {
        reason.show(AIReason(title:"翻译失败",message:"AI 服务暂时不可用：资源保护已开启：local-work。已阻止 qwen-fast 请求，不会自动拉起本地模型；完成训练后执行 `ai router quiet off`。（约 60 秒后可重试）"))
        reasonWindow = NSWindow(contentRect:NSRect(x:0,y:0,width:380,height:260),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        reasonWindow.title = "轻语 · 失败气泡外观测试"
        let host = NSHostingView(rootView:ReasonPanelView(model:reason,opensBelow:true,retry:{},settings:{},close:{}))
        host.frame = NSRect(x:0,y:0,width:380,height:260)
        reasonWindow.contentView = host
        reasonWindow.setFrameOrigin(NSPoint(x:window.frame.minX,y:window.frame.minY-300))
        reasonWindow.orderFront(nil)
    }
    func show() {
        let anchor = window.contentView!.subviews[0]
        popover.show(relativeTo:anchor.bounds,of:anchor,preferredEdge:.minY)
    }
}
@main struct CandidatePreview {
    @MainActor static func main() {
        // Headless render: prove the failure bubble has real content and lays out,
        // without needing a window, screen-recording permission, or WhatsApp.
        if CommandLine.arguments.contains("--render-reason") {
            let model = ReasonModel()
            model.show(AIReason(title:"翻译失败",message:"AI 服务暂时不可用：资源保护已开启：local-work。已阻止 qwen-fast 请求，不会自动拉起本地模型；完成训练后执行 `ai router quiet off`。（约 60 秒后可重试）",hint:"读不到 WhatsApp 的输入框，只能在这里显示原因。"))
            let view = ReasonPanelView(model:model,opensBelow:true,retry:{},settings:{},close:{})
                .frame(width:354,height:200).background(Color.white)
            let renderer = ImageRenderer(content:view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data:tiff),
                  let png = bitmap.representation(using:.png,properties:[:]) else {
                print("RENDER FAILED"); exit(1)
            }
            let path = "/tmp/lightu-reason.png"
            try? png.write(to:URL(fileURLWithPath:path))
            print("RENDERED \(path) \(Int(image.size.width))x\(Int(image.size.height))")
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = PreviewDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
