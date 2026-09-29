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
    @AppStorage("autoShowCandidates") private var autoShowCandidates=false
    @AppStorage("hoverTranslateEnabled") private var hoverTranslateEnabled=true
    @AppStorage("historyEnabled") private var historyEnabled=true
    @AppStorage("historyLimit") private var historyLimit=50
    var body:some View {
        Form {
            Section("启动") {
                Toggle("登录 Mac 后自动启动轻语",isOn:$launchAtLogin).onChange(of:launchAtLogin){ updateLoginItem($0) }
                if !loginMessage.isEmpty { Text(loginMessage).font(.caption).foregroundStyle(.secondary) }
            }
            Section("润色") {
                Toggle("草稿停止输入约 2 秒后自动弹出候选",isOn:$autoShowCandidates)
                Text("只读取 WhatsApp 当前输入框的草稿并在停止输入后自动生成两条英文候选，不自动发送。也可随时点击输入框旁的 ✨ 手动生成。").font(.caption).foregroundStyle(.secondary)
            }
            Section("翻译") {
                Toggle("悬停消息时显示翻译按钮",isOn:$hoverTranslateEnabled)
                Text("关闭后不再读取消息列表，悬停按钮与译文写入输入框的功能一并停用。").font(.caption).foregroundStyle(.secondary)
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
    @State private var profileName=UserDefaults.standard.string(forKey:"profileName") ?? ""
    @State private var casualPrompt=UserDefaults.standard.string(forKey:"casualPrompt") ?? APIClient.defaultCasualPrompt
    @State private var formalPrompt=UserDefaults.standard.string(forKey:"formalPrompt") ?? APIClient.defaultFormalPrompt
    @State private var key=""
    @State private var profiles:[AIProfile]=[]
    @State private var selectedEndpoint:String?
    @State private var hasSavedKey=false
    @State private var testing=false
    @State private var message=""; @State private var ok=true
    @State private var promptMessage=""; @State private var promptOK=true
    @State private var keyCheckTask:Task<Void,Never>?
    @State private var testTask:Task<Void,Never>?
    var body:some View {
        Form {
            Section("连接 AI 服务") {
                Text("润色时只发送本次草稿。历史记录不会发送，服务可能按用量收费。").foregroundStyle(.secondary)
                if !profiles.isEmpty {
                    HStack {
                        Picker("历史连接",selection:$selectedEndpoint) {
                            Text("手动输入").tag(String?.none)
                            ForEach(profiles){ profile in
                                Text(AIProfileStore.displayName(endpoint:profile.endpoint,name:profile.name)).tag(profile.endpoint as String?)
                            }
                        }.onChange(of:selectedEndpoint){ loadSelected($0) }
                        if selectedEndpoint != nil {
                            Button("删除",role:.destructive,action:deleteSelectedProfile).help("删除这条历史连接")
                        }
                    }
                }
                TextField("服务地址",text:$endpoint).onChange(of:endpoint){ _ in connectionChanged() }
                TextField("模型名称",text:$model)
                TextField("配置名称（可选，便于在历史里认出它）",text:$profileName)
                SecureField("填写新密钥；留空保留已保存密钥",text:$key)
                Text(hasSavedKey ? "此地址已保存密钥，可以直接测试。" : "此地址还没有保存密钥。").font(.caption).foregroundStyle(hasSavedKey ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                HStack {
                    if testing { ProgressView().controlSize(.small) }
                    Button(testing ? "取消测试" : "测试连接") { if testing { cancelTest() } else { testConnection() } }
                    Spacer()
                    Button("保存连接",action:saveConnection).buttonStyle(.borderedProminent).tint(.teal)
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(ok ? .secondary:.primary) }
                Text("密钥保存在 macOS 钥匙串中。服务须支持 Chat Completions（HTTPS，本机代理可用 http）。").font(.caption).foregroundStyle(.secondary)
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
                    Button("保存提示词",action:savePrompts).buttonStyle(.borderedProminent).tint(.teal)
                }
                if !promptMessage.isEmpty { Text(promptMessage).font(.caption).foregroundStyle(promptOK ? .secondary:.primary) }
            }
        }.formStyle(.grouped).onAppear {
            profiles=AIProfileStore.load()
            selectedEndpoint=profiles.first(where:{$0.endpoint == currentEndpoint})?.endpoint
            refreshSavedKey()
        }
    }

    private var currentEndpoint:String { endpoint.trimmingCharacters(in:.whitespacesAndNewlines) }
    private var currentModel:String { model.trimmingCharacters(in:.whitespacesAndNewlines) }

    // 服务地址变了：密钥字段清空，历史选中项跟着对上同地址的配置。
    private func connectionChanged() {
        key="";message=""
        let match=profiles.first(where:{$0.endpoint == currentEndpoint})?.endpoint
        if selectedEndpoint != match { selectedEndpoint=match }
        refreshSavedKey()
    }

    private func loadSelected(_ selected:String?) {
        guard let selected,let profile=profiles.first(where:{$0.endpoint == selected}),
              profile.endpoint != currentEndpoint else { return }
        endpoint=profile.endpoint; model=profile.model; profileName=profile.name
        key="";message=""
        refreshSavedKey()
    }

    private func deleteSelectedProfile() {
        guard let selected=selectedEndpoint,
              let profile=profiles.first(where:{$0.endpoint == selected}) else { return }
        profiles=AIProfileStore.remove(endpoint:selected,from:profiles)
        AIProfileStore.save(profiles)
        selectedEndpoint=nil
        ok=true;message="已删除「\(AIProfileStore.displayName(endpoint:profile.endpoint,name:profile.name))」。"
    }

    private func refreshSavedKey() {
        keyCheckTask?.cancel()
        let endpoint=currentEndpoint
        keyCheckTask=Task { @MainActor in
            try? await Task.sleep(nanoseconds:200_000_000)
            guard !Task.isCancelled else { return }
            let stored=(try? SecretStore.read(endpoint)) ?? ""
            hasSavedKey = !stored.isEmpty
        }
    }

    // 真实发一条最小润色请求：连通性、密钥、模型、JSON 输出格式一次验证完。
    private func testConnection() {
        let trimmedKey=key.trimmingCharacters(in:.whitespacesAndNewlines)
        let configuration: APIConfiguration
        do {
            let effective=try trimmedKey.isEmpty ? SecretStore.read(currentEndpoint) : trimmedKey
            configuration=APIConfiguration(endpoint:currentEndpoint,model:currentModel,key:effective,casualPrompt:casualPrompt,formalPrompt:formalPrompt)
            _=try APIClient.makeRequest(text:"Hello",configuration:configuration)
        } catch { ok=false;message=(error as? PolishError)?.message ?? error.localizedDescription; return }
        testing=true;ok=true;message="正在测试连接…"
        testTask=Task { @MainActor in
            let started=Date()
            do {
                _=try await APIClient().polish("Hello",configuration:configuration)
                let seconds=String(format:"%.1f",Date().timeIntervalSince(started))
                ok=true;message="测试成功 · \(seconds) 秒"
            } catch is CancellationError {
                ok=true;message="已取消测试。"
            } catch {
                ok=false;message=(error as? PolishError)?.message ?? error.localizedDescription
            }
            testing=false
        }
    }

    private func cancelTest() {
        testTask?.cancel()
    }

    private func saveConnection() {
        let trimmedKey=key.trimmingCharacters(in:.whitespacesAndNewlines)
        do {
            let effective=try trimmedKey.isEmpty ? SecretStore.read(currentEndpoint) : trimmedKey
            _=try APIClient.makeRequest(text:"Hello",configuration:APIConfiguration(endpoint:currentEndpoint,model:currentModel,key:effective,casualPrompt:casualPrompt,formalPrompt:formalPrompt))
            if !trimmedKey.isEmpty { try SecretStore.save(trimmedKey,endpoint:currentEndpoint) }
            UserDefaults.standard.set(currentEndpoint,forKey:"endpoint");UserDefaults.standard.set(currentModel,forKey:"model")
            profiles=AIProfileStore.upsert(AIProfile(endpoint:currentEndpoint,name:profileName,model:currentModel),into:profiles)
            AIProfileStore.save(profiles)
            selectedEndpoint=currentEndpoint
            key="";hasSavedKey=true
            ok=true;message="已保存，之后可以在「历史连接」里一键切换回来。"
        } catch { ok=false;message=(error as? PolishError)?.message ?? error.localizedDescription }
    }

    private func savePrompts() {
        UserDefaults.standard.set(casualPrompt,forKey:"casualPrompt")
        UserDefaults.standard.set(formalPrompt,forKey:"formalPrompt")
        promptOK=true;promptMessage="提示词已保存。"
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
