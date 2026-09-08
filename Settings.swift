import SwiftUI
import Security
import ApplicationServices

struct SecretStore {
    static let service = "com.xy.english-polish.api"
    static func account(_ endpoint: String) -> String { endpoint.trimmingCharacters(in:CharacterSet(charactersIn:" /\n\t")) }
    static func query(_ endpoint: String) -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account(endpoint)]
    }
    static func read(_ endpoint: String) throws -> String {
        var q = query(endpoint); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data:data,encoding:.utf8) else {
            throw PolishError("无法读取钥匙串中的密钥（\(status)）。请在设置中重新保存。")
        }
        return key
    }
    static func save(_ key: String, endpoint: String) throws {
        let q = query(endpoint)
        let fields: [String:Any] = [kSecValueData as String:Data(key.utf8)]
        var status = SecItemUpdate(q as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            var record = q.merging(fields) { _,new in new }
            record[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(record as CFDictionary,nil)
        }
        guard status == errSecSuccess else { throw PolishError("密钥保存失败（\(status)），设置尚未保存。") }
    }
}

struct SettingsView: View {
    @State private var endpoint = UserDefaults.standard.string(forKey:"endpoint") ?? "https://api.openai.com/v1"
    @State private var model = UserDefaults.standard.string(forKey:"model") ?? ""
    @State private var key = ""
    @State private var message = ""
    @State private var saved = false
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:12) {
                Image(systemName:"sparkles").font(.system(size:30)).foregroundStyle(.teal)
                VStack(alignment:.leading) {
                    Text("轻语").font(.title.bold())
                    Text("让英文表达更自然，意思更清楚。").foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("1 · 连接 AI 服务").font(.headline)
            Text("点击润色时，只把本次输入的原文发送到下方服务。聊天记录不会上传。服务可能按用量收费。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            VStack(alignment:.leading,spacing:6) {
                Text("服务地址").font(.caption)
                TextField("https://api.openai.com/v1",text:$endpoint)
                    .onChange(of:endpoint) { _ in key = ""; saved = false; message = "服务已更换，请填写对应密钥；留空使用该地址已保存的密钥。" }
                Text("支持 Chat Completions 和 JSON 模式的 HTTPS 服务").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment:.leading,spacing:6) {
                Text("模型名称").font(.caption)
                TextField("填写 AI 服务提供的模型名称",text:$model)
            }
            VStack(alignment:.leading,spacing:6) {
                Text("API 密钥").font(.caption)
                SecureField("填写新密钥；留空保留此服务已保存的密钥",text:$key)
                Text("密钥保存在 macOS 钥匙串中。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("保存 AI 设置",action:save).buttonStyle(.borderedProminent).tint(.teal)
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(saved ? .secondary : .primary).fixedSize(horizontal:false,vertical:true) }
            }
            Divider()
            Text("2 · 允许读取和替换草稿").font(.headline)
            Text("在系统设置 → 隐私与安全性 → 辅助功能中，允许“轻语”。然后返回 WhatsApp 输入英文，点击输入框旁的 ✨。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Button("打开辅助功能设置") {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            Text("首次使用前请确认中文意思；替换后由你发送。系统授权需要你亲自完成。").font(.caption).foregroundStyle(.secondary)
        }.textFieldStyle(.roundedBorder).padding(26).frame(width:510)
    }
    private func save() {
        do {
            let cleanEndpoint = endpoint.trimmingCharacters(in:.whitespacesAndNewlines)
            let cleanModel = model.trimmingCharacters(in:.whitespacesAndNewlines)
            let cleanKey = key.trimmingCharacters(in:.whitespacesAndNewlines)
            let effectiveKey = try cleanKey.isEmpty ? SecretStore.read(cleanEndpoint) : cleanKey
            _ = try APIClient.makeRequest(text:"Hello",configuration:APIConfiguration(endpoint:cleanEndpoint,model:cleanModel,key:effectiveKey))
            if !cleanKey.isEmpty { try SecretStore.save(cleanKey,endpoint:cleanEndpoint) }
            UserDefaults.standard.set(cleanEndpoint,forKey:"endpoint")
            UserDefaults.standard.set(cleanModel,forKey:"model")
            key = ""; saved = true; message = "已保存。回到 WhatsApp 即可使用。"
        } catch { saved = false; message = error.localizedDescription }
    }
}
