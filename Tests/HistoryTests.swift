import Foundation

@main
struct HistoryTests {
    @MainActor static func main() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        let file=directory.appendingPathComponent("history.json")
        let suite="com.xy.english-polish.tests.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defaults.set(true,forKey:"historyEnabled");defaults.set(10,forKey:"historyLimit")
        let store=HistoryStore(fileURL:file)
        let result=PolishResult(ambiguous:false,question:"",options:[Suggestion(english:"I'm here.",chinese:"我在。"),Suggestion(english:"I am present.",chinese:"我在场。")])
        for index in 0..<12 { store.add(source:"draft \(index)",result:result,defaults:defaults) }
        precondition(store.entries.count==10)
        precondition(store.entries.first?.source=="draft 11")
        precondition(store.entries.last?.source=="draft 2")
        print("PASS: history keeps newest configured maximum")
        let restored=HistoryStore(fileURL:file)
        precondition(restored.entries.count==10)
        print("PASS: history persists locally")
        store.clear();precondition(store.entries.isEmpty)
        print("PASS: history can be cleared")
        defaults.removePersistentDomain(forName:suite)
    }
}
