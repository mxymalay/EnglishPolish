import SwiftUI
import Security
import ServiceManagement
import ApplicationServices

struct SecretStore {
    static let service = "com.xy.english-polish.api"
    static func account(_ endpoint:String)->String { endpoint.trimmingCharacters(in:CharacterSet(charactersIn:" /\n\t")) }
    static func query(_ endpoint:String)->[String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account(endpoint)] }
    static func read(_ endpoint:String)throws->String {
        var q=query(endpoint); q[kSecReturnData as String]=true; q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?; let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound { return "" }
        guard status==errSecSuccess,let data=result as? Data,let key=String(data:data,encoding:.utf8) else { throw PolishError("无法读取钥匙串中的密钥（\(status)）。") }
        return key
    }
    static func save(_ key:String,endpoint:String)throws {
        let q=query(endpoint); let fields:[String:Any]=[kSecValueData as String:Data(key.utf8)]
        var status=SecItemUpdate(q as CFDictionary,fields as CFDictionary)
        if status==errSecItemNotFound {
            var record=q.merging(fields){_,new in new}; record[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status=SecItemAdd(record as CFDictionary,nil)
        }
        guard status==errSecSuccess else { throw PolishError("密钥保存失败（\(status)）。") }
    }
}

struct SettingsView:View {
    @ObservedObject var history:HistoryStore
    var body:some View {
        TabView {
            GeneralSettingsPage(history:history).tabItem { Label("常规",systemImage:"gearshape") }
            AISettingsPage().tabItem { Label("AI 服务",systemImage:"sparkles") }
            HistorySettingsPage(history:history).tabItem { Label("历史",systemImage:"clock.arrow.circlepath") }
            PermissionSettingsPage().tabItem { Label("权限",systemImage:"hand.raised") }
        }.padding(18).frame(width:620,height:520)
    }
}

struct GeneralSettingsPage:View {
    @ObservedObject var history:HistoryStore
    @State private var launchAtLogin=SMAppService.mainApp.status == .enabled
    @State private var loginMessage=""
    @AppStorage("historyEnabled") private var historyEnabled=true
    @AppStorage("historyLimit") private var historyLimit=50
    var body:some View {
        Form {
            Section("启动") {
                Toggle("登录 Mac 后自动启动轻语",isOn:$launchAtLogin).onChange(of:launchAtLogin){ updateLoginItem($0) }
                if !loginMessage.isEmpty { Text(loginMessage).font(.caption).foregroundStyle(.secondary) }
            }
            Section("历史") {
                Toggle("保存润色历史",isOn:$historyEnabled)
                Stepper("最多保留 \(historyLimit) 条",value:$historyLimit,in:10...200,step:10)
                    .disabled(!historyEnabled).onChange(of:historyLimit){ history.trim(to:$0) }
                Text("当前保存 \(history.entries.count) 条，只保存在这台 Mac。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private func updateLoginItem(_ enabled:Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginMessage=SMAppService.mainApp.status == .requiresApproval ? "需要在系统设置 → 通用 → 登录项中允许轻语。" : (enabled ? "已开启开机启动。" : "已关闭开机启动。")
        } catch { launchAtLogin=SMAppService.mainApp.status == .enabled; loginMessage="无法更新开机启动：\(error.localizedDescription)" }
    }
}

struct AISettingsPage:View {
    @State private var endpoint=UserDefaults.standard.string(forKey:"endpoint") ?? "https://api.openai.com/v1"
    @State private var model=UserDefaults.standard.string(forKey:"model") ?? ""
    @State private var casualPrompt=UserDefaults.standard.string(forKey:"casualPrompt") ?? APIClient.defaultCasualPrompt
    @State private var formalPrompt=UserDefaults.standard.string(forKey:"formalPrompt") ?? APIClient.defaultFormalPrompt
    @State private var key=""; @State private var message=""; @State private var saved=false
    var body:some View {
        Form {
            Section("连接 AI 服务") {
                Text("润色时只发送本次草稿。历史记录不会发送，服务可能按用量收费。").foregroundStyle(.secondary)
                TextField("服务地址",text:$endpoint).onChange(of:endpoint){ _ in key="";saved=false;message="服务已更换，请填写对应密钥。" }
                TextField("模型名称",text:$model)
                SecureField("填写新密钥；留空保留已保存密钥",text:$key)
                Text("密钥保存在 macOS 钥匙串中。服务必须支持 HTTPS Chat Completions JSON 模式。").font(.caption).foregroundStyle(.secondary)
            }
            Section("自定义提示词") {
                Text("下面两个框分别控制候选框里的第一句和第二句。输出格式和原意保护规则由轻语继续管理。").font(.caption).foregroundStyle(.secondary)
                Text("候选 1 · 日常口语").font(.headline)
                TextEditor(text:$casualPrompt).font(.system(.body,design:.monospaced)).frame(minHeight:82)
                    .overlay(RoundedRectangle(cornerRadius:7).stroke(.primary.opacity(0.12)))
                Text("候选 2 · 正式书面语").font(.headline)
                TextEditor(text:$formalPrompt).font(.system(.body,design:.monospaced)).frame(minHeight:82)
                    .overlay(RoundedRectangle(cornerRadius:7).stroke(.primary.opacity(0.12)))
                HStack {
                    Button("恢复两个默认提示词") { casualPrompt=APIClient.defaultCasualPrompt;formalPrompt=APIClient.defaultFormalPrompt }
                    Spacer()
                    Button("保存 AI 设置",action:save).buttonStyle(.borderedProminent).tint(.teal)
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(saved ? .secondary:.primary) }
            }
        }.formStyle(.grouped)
    }
    private func save() {
        do {
            let e=endpoint.trimmingCharacters(in:.whitespacesAndNewlines),m=model.trimmingCharacters(in:.whitespacesAndNewlines),k=key.trimmingCharacters(in:.whitespacesAndNewlines)
            let effective=try k.isEmpty ? SecretStore.read(e):k
            _=try APIClient.makeRequest(text:"Hello",configuration:APIConfiguration(endpoint:e,model:m,key:effective,casualPrompt:casualPrompt,formalPrompt:formalPrompt))
            if !k.isEmpty { try SecretStore.save(k,endpoint:e) }
            UserDefaults.standard.set(e,forKey:"endpoint");UserDefaults.standard.set(m,forKey:"model")
            UserDefaults.standard.set(casualPrompt,forKey:"casualPrompt");UserDefaults.standard.set(formalPrompt,forKey:"formalPrompt")
            key="";saved=true;message="已保存。"
        } catch { saved=false;message=error.localizedDescription }
    }
}

struct HistorySettingsPage:View {
    @ObservedObject var history:HistoryStore
    @State private var confirmClear=false
    var body:some View {
        VStack(spacing:12) {
            HStack { Text("润色历史").font(.title2.bold());Spacer();Text("\(history.entries.count) 条").foregroundStyle(.secondary);Button("清空",role:.destructive){confirmClear=true}.disabled(history.entries.isEmpty) }
            if history.entries.isEmpty {
                VStack(spacing:10) { Image(systemName:"clock").font(.system(size:34)).foregroundStyle(.secondary);Text("暂无历史").font(.headline);Text("生成的两条候选会保存在这里。").foregroundStyle(.secondary) }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            else { ScrollView { LazyVStack(spacing:10) { ForEach(history.entries){ entry in
                VStack(alignment:.leading,spacing:7) {
                    Text(entry.date.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                    Text(entry.source).font(.callout.weight(.medium)).lineLimit(2)
                    ForEach(Array(entry.options.prefix(2).enumerated()),id:\.offset){ index,option in HStack(alignment:.top,spacing:7){Text("\(index+1)").font(.caption2).foregroundStyle(.secondary);Text(option.english).font(.callout).textSelection(.enabled)} }
                }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:10))
            }}}}
        }.padding(8).confirmationDialog("清空所有润色历史？",isPresented:$confirmClear,titleVisibility:.visible){Button("清空历史",role:.destructive){history.clear()};Button("取消",role:.cancel){}}
    }
}

struct PermissionSettingsPage:View {
    @State private var allowed=AXIsProcessTrusted()
    var body:some View {
        Form {
            Section("辅助功能") {
                Label(allowed ? "已允许当前版本":"尚未允许当前版本",systemImage:allowed ? "checkmark.circle.fill":"exclamationmark.triangle.fill").foregroundStyle(allowed ? .green:.orange)
                Text("轻语使用固定应用身份 com.xy.english-polish。首次从旧版本升级后需要重新添加一次，后续更新沿用同一身份。").foregroundStyle(.secondary)
                HStack { Button("打开辅助功能设置",action:openAccessibility);Button("刷新状态"){allowed=AXIsProcessTrusted()} }
            }
            Section("用途") { Text("权限只用于读取当前 WhatsApp 草稿、定位浮动按钮，并在你点选候选后替换草稿。轻语不会自动发送消息。").foregroundStyle(.secondary) }
        }.formStyle(.grouped).onAppear{allowed=AXIsProcessTrusted()}
    }
    private func openAccessibility() {
        let options=[kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary;_=AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
