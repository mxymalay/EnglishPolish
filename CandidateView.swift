import SwiftUI

struct CandidateBubbleShape: Shape {
    let opensBelow: Bool
    func path(in rect: CGRect) -> Path {
        let arrowWidth: CGFloat = 18, arrowHeight: CGFloat = 9, radius: CGFloat = 13
        let top = opensBelow ? arrowHeight : 0
        let bottom = opensBelow ? rect.height : rect.height - arrowHeight
        let tipY: CGFloat = opensBelow ? 0 : rect.height
        var path = Path()
        path.move(to:CGPoint(x:rect.minX,y:top + radius))
        path.addArc(tangent1End:CGPoint(x:rect.minX,y:top),tangent2End:CGPoint(x:rect.minX + radius,y:top),radius:radius)
        if opensBelow {
            path.addLine(to:CGPoint(x:rect.midX - arrowWidth/2,y:top))
            path.addLine(to:CGPoint(x:rect.midX,y:tipY))
            path.addLine(to:CGPoint(x:rect.midX + arrowWidth/2,y:top))
        }
        path.addLine(to:CGPoint(x:rect.maxX - radius,y:top))
        path.addArc(tangent1End:CGPoint(x:rect.maxX,y:top),tangent2End:CGPoint(x:rect.maxX,y:top + radius),radius:radius)
        path.addLine(to:CGPoint(x:rect.maxX,y:bottom - radius))
        path.addArc(tangent1End:CGPoint(x:rect.maxX,y:bottom),tangent2End:CGPoint(x:rect.maxX - radius,y:bottom),radius:radius)
        if !opensBelow {
            path.addLine(to:CGPoint(x:rect.midX + arrowWidth/2,y:bottom))
            path.addLine(to:CGPoint(x:rect.midX,y:tipY))
            path.addLine(to:CGPoint(x:rect.midX - arrowWidth/2,y:bottom))
        }
        path.addLine(to:CGPoint(x:rect.minX + radius,y:bottom))
        path.addArc(tangent1End:CGPoint(x:rect.minX,y:bottom),tangent2End:CGPoint(x:rect.minX,y:bottom - radius),radius:radius)
        path.addLine(to:CGPoint(x:rect.minX,y:top + radius))
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
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(hovered ? .multicolor : .monochrome)
                .foregroundStyle(hovered ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 26)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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

struct PinButton: View {
    let pinned: Bool
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(pinned ? Color.accentColor : Color.secondary.opacity(hovered ? 1 : 0.7))
                .frame(width: 20, height: 20)
                .background(hovered || pinned ? Color.primary.opacity(0.07) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(pinned ? "取消固定" : "固定候选框")
        .accessibilityLabel(pinned ? "取消固定候选框" : "固定候选框")
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
            if model.busy {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("正在润色…").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                .frame(minHeight: 58)
            } else if let result = model.result {
                if result.ambiguous {
                    Text(result.question).font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.leading, 12).padding(.trailing, 24).padding(.top, 10)
                }
                candidateList(result)
            }
            if !model.message.isEmpty {
                Text(model.message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12).padding(.trailing, 24).padding(.vertical, 12)
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
        .overlay(alignment: .topTrailing) {
            PinButton(pinned: model.pinned, action: togglePin).padding(6)
        }
        .onExitCommand(perform: close)
    }
    // Short results render as a plain list so the panel hugs the content exactly;
    // the estimate is only used to decide whether the rare very-long draft needs
    // a bounded scroll area (which is then always filled, so no blank space shows).
    @ViewBuilder
    private func candidateList(_ result: PolishResult) -> some View {
        let rows = VStack(spacing: 0) {
            ForEach(Array(result.options.enumerated()), id: \.offset) { index, option in
                if index > 0 { Divider().padding(.horizontal, 12) }
                CandidateRow(option: option, showMeaning: result.ambiguous) { choose(index) }
                    .padding(.top, index == 0 ? 2 : 0)
                    .padding(.trailing, index == 0 ? 16 : 0)
                    .contextMenu {
                        Button("复制英文") { model.selected = index; model.copy() }
                    }
            }
        }
        if contentHeight(result) >= 320 {
            ScrollView { rows }.frame(height: 320)
        } else {
            rows
        }
    }
    private func contentHeight(_ result: PolishResult) -> CGFloat {
        let lines = result.options.reduce(0) { total, option in
            total + max(1, Int(ceil(Double(option.english.count) / 39)))
                + (result.ambiguous ? max(1, Int(ceil(Double(option.chinese.count) / 23))) : 0)
        }
        return CGFloat(lines) * 20 + 52
    }
}
