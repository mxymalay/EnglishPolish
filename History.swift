import Foundation
import Combine

struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let source: String
    let options: [Suggestion]
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published private(set) var entries: [HistoryEntry] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL { self.fileURL = fileURL }
        else {
            let base = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
                .appendingPathComponent("com.xy.english-polish",isDirectory:true)
            self.fileURL = base.appendingPathComponent("history.json")
        }
        load()
    }

    static func maximum(_ defaults: UserDefaults = .standard) -> Int {
        let value = defaults.integer(forKey:"historyLimit")
        return min(200,max(10,value == 0 ? 50 : value))
    }

    func add(source: String, result: PolishResult, defaults: UserDefaults = .standard) {
        if defaults.object(forKey:"historyEnabled") == nil { defaults.set(true,forKey:"historyEnabled") }
        guard defaults.bool(forKey:"historyEnabled") else { return }
        entries.insert(HistoryEntry(id:UUID(),date:Date(),source:source,options:Array(result.options.prefix(2))),at:0)
        trim(to:Self.maximum(defaults)); save()
    }

    func trim(to limit: Int) {
        if entries.count > limit { entries.removeLast(entries.count-limit); save() }
    }

    func clear() { entries.removeAll(); save() }

    private func load() {
        guard let data = try? Data(contentsOf:fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self,from:data) else { return }
        entries = Array(decoded.prefix(Self.maximum()))
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at:fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories:true,
                                                    attributes:[.posixPermissions:0o700])
            let data = try JSONEncoder().encode(entries)
            try data.write(to:fileURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:fileURL.path)
        } catch {
            // History is optional. AI generation and WhatsApp replacement must remain usable.
        }
    }
}
