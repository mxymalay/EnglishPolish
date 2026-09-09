import SwiftUI

struct CandidateBubbleShape: Shape {
    let opensBelow: Bool
    func path(in rect: CGRect) -> Path {
        let arrowWidth: CGFloat = 18, arrowHeight: CGFloat = 9, radius: CGFloat = 13
        let body = opensBelow
            ? CGRect(x:0,y:arrowHeight,width:rect.width,height:max(0,rect.height-arrowHeight))
            : CGRect(x:0,y:0,width:rect.width,height:max(0,rect.height-arrowHeight))
        var path = Path(roundedRect:body,cornerRadius:radius)
        let baseY = opensBelow ? arrowHeight + 1 : rect.height - arrowHeight - 1
        let tipY = opensBelow ? 0 : rect.height
        path.move(to:CGPoint(x:rect.midX-arrowWidth/2,y:baseY))
        path.addLine(to:CGPoint(x:rect.midX,y:tipY))
        path.addLine(to:CGPoint(x:rect.midX+arrowWidth/2,y:baseY))
        path.closeSubpath()
        return path
    }
}

struct CandidatePanelView: View {
    @ObservedObject var model: PolishModel
    let opensBelow: Bool
    var choose: (Int) -> Void
    var togglePin: () -> Void
    var close: () -> Void
    var settings: () -> Void
    var body: some View {
        CandidateView(model:model,choose:choose,togglePin:togglePin,close:close,settings:settings)
            .padding(.top,opensBelow ? 9 : 0)
            .padding(.bottom,opensBelow ? 0 : 9)
            .background(.regularMaterial,in:CandidateBubbleShape(opensBelow:opensBelow))
            .overlay(CandidateBubbleShape(opensBelow:opensBelow).stroke(.primary.opacity(0.13),lineWidth:0.7))
            .shadow(color:.black.opacity(0.22),radius:12,y:opensBelow ? 3 : -3)
            .padding(12)
    }
}

struct PolishTrigger: View {
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovered ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 26)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.09)))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("润色 WhatsApp 草稿")
        .help("润色英文")
    }
}

struct CandidateRow: View {
    let option: Suggestion
    let showMeaning: Bool
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Text(option.english).font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                if showMeaning {
                    Text(option.chinese).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .contentShape(Rectangle())
            .background(hovered ? Color.accentColor.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("点击替换；右键可复制")
    }
}

struct CandidateView: View {
    @ObservedObject var model: PolishModel
    var choose: (Int) -> Void
    var togglePin: () -> Void
    var close: () -> Void
    var settings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button(action: togglePin) {
                    Image(systemName: model.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(model.pinned ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.plain)
                .help(model.pinned ? "取消固定" : "固定候选框")
                .accessibilityLabel(model.pinned ? "取消固定候选框" : "固定候选框")
            }
            .frame(height: 23)
            .padding(.horizontal, 4)
            if model.busy {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("正在润色…").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 12).padding(.bottom, 12)
            } else if let result = model.result {
                if result.ambiguous {
                    Text(result.question).font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.top, 10)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(result.options.enumerated()), id: \.offset) { index, option in
                            if index > 0 { Divider().padding(.horizontal, 12) }
                            CandidateRow(option: option, showMeaning: result.ambiguous) { choose(index) }
                                .contextMenu {
                                    Button("复制英文") { model.selected = index; model.copy() }
                                }
                        }
                    }
                }
                .frame(height: contentHeight(result))
            }
            if !model.message.isEmpty {
                Text(model.message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
                HStack {
                    Button("重试") { model.generate() }
                    Button("设置", action: settings)
                    Spacer()
                    Button("关闭", action: close)
                }.controlSize(.small).padding([.horizontal, .bottom], 12)
            }
        }
        .padding(5)
        .frame(width: 350)
        .onExitCommand(perform: close)
    }
    private func contentHeight(_ result: PolishResult) -> CGFloat {
        // Reserve space for wrapping while bounding long drafts to a scrollable dictionary-sized panel.
        let lines = result.options.reduce(0) { total, option in
            total + max(1, Int(ceil(Double(option.english.count) / 39)))
                + (result.ambiguous ? max(1, Int(ceil(Double(option.chinese.count) / 23))) : 0)
        }
        return min(320, max(96, CGFloat(lines) * 20 + 52))
    }
}
