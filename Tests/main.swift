import Foundation
import CoreGraphics

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if !condition() { fatalError("FAIL: \(name)") }
    print("PASS: \(name)")
}
func rejects(_ name: String, _ block: () throws -> Void) {
    do { try block(); fatalError("FAIL: \(name)") } catch { print("PASS: \(name)") }
}
let normal = Data(#"{"ambiguous":false,"question":"","options":[{"english":"Could you send it tomorrow?","chinese":"你能明天发给我吗？"}]}"#.utf8)
let decodedNormal = try PolishResult.decode(normal)
check(decodedNormal.options.count == 1, "normal reply")
let ambiguous = Data(#"{"ambiguous":true,"question":"谁需要明天发送？","options":[{"english":"Could you send it tomorrow?","chinese":"请对方明天发送"},{"english":"I can send it tomorrow.","chinese":"我可以明天发送"}]}"#.utf8)
let decodedAmbiguous = try PolishResult.decode(ambiguous)
check(decodedAmbiguous.ambiguous, "ambiguity requires a choice")
rejects("empty result rejected") { _ = try PolishResult.decode(Data(#"{"ambiguous":false,"question":"","options":[]}"#.utf8)) }
rejects("blank English rejected") { _ = try PolishResult.decode(Data(#"{"ambiguous":false,"question":"","options":[{"english":" ","chinese":"你好"}]}"#.utf8)) }
rejects("single ambiguous choice rejected") { _ = try PolishResult.decode(Data(#"{"ambiguous":true,"question":"哪个意思？","options":[{"english":"Hello","chinese":"你好"}]}"#.utf8)) }
rejects("invalid JSON rejected") { _ = try PolishResult.decode(Data("oops".utf8)) }
let draft = DraftIdentity(window: "1", chat: "A", text: "I is here", field: "composer")
check(draft.mayReplace(with: draft), "same draft allowed")
check(!draft.mayReplace(with: DraftIdentity(window:"1", chat:"A", text:"I is here now", field:"composer")), "new typing protected")
check(!draft.mayReplace(with: DraftIdentity(window:"1", chat:"B", text:"I is here", field:"composer")), "other chat protected even identical text")
check(!draft.mayReplace(with: DraftIdentity(window:"2", chat:"A", text:"I is here", field:"composer")), "other window protected")
check(lastCharacterRange("Hi 👋") == NSRange(location:3, length:2), "emoji UTF16 range")
check(lastCharacterRange("") == nil, "empty text has no character bounds")
let p = Placement.buttonRect(axRect:CGRect(x:100,y:200,width:10,height:20), primaryHeight:900, visible:CGRect(x:0,y:0,width:1440,height:900))
check(p.minX == 116 && p.minY == 674, "AX top-left to AppKit bottom-left")
let edge = Placement.buttonRect(axRect:CGRect(x:1430,y:880,width:10,height:20), primaryHeight:900, visible:CGRect(x:0,y:0,width:1440,height:900))
check(edge.maxX <= 1434 && edge.minY >= 6, "button stays on screen")
let config = APIConfiguration(endpoint:"https://example.com/v1", model:"test-model", key:"test-secret")
let request = try APIClient.makeRequest(text:"I is here", configuration:config)
check(request.url?.absoluteString == "https://example.com/v1/chat/completions", "API URL")
check(request.value(forHTTPHeaderField:"Authorization") == "Bearer test-secret", "authentication header")
let body = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
check(body["model"] as? String == "test-model", "configured model used")
check((body["messages"] as! [[String:Any]]).count == 2, "only instructions and current draft sent")
rejects("HTTP endpoint rejected") { _ = try APIClient.makeRequest(text:"Hi",configuration:APIConfiguration(endpoint:"http://example.com/v1",model:"x",key:"y")) }
rejects("missing key rejected") { _ = try APIClient.makeRequest(text:"Hi",configuration:APIConfiguration(endpoint:"https://example.com/v1",model:"x",key:"")) }
rejects("empty draft rejected") { _ = try APIClient.makeRequest(text:"  ",configuration:config) }
let envelope = try JSONSerialization.data(withJSONObject:["choices":[["finish_reason":"stop","message":["content":String(data:normal,encoding:.utf8)!]]]])
let parsedEnvelope = try APIClient.parse(data:envelope,status:200)
check(parsedEnvelope.options.first?.english == "Could you send it tomorrow?", "real response envelope parsed")
rejects("HTTP failure not accepted") { _ = try APIClient.parse(data:envelope,status:401) }
let truncated = try JSONSerialization.data(withJSONObject:["choices":[["finish_reason":"length","message":["content":String(data:normal,encoding:.utf8)!]]]])
rejects("truncated generation rejected") { _ = try APIClient.parse(data:truncated,status:200) }
check(SessionPolicy.isReady(["kCGSSessionOnConsoleKey":true,"kCGSessionLoginDoneKey":true]), "valid logged-in console is ready")
check(!SessionPolicy.isReady(["kCGSSessionOnConsoleKey":true,"kCGSessionLoginDoneKey":true,"CGSSessionScreenIsLocked":true]), "locked session deferred")
check(!SessionPolicy.isReady(["kCGSessionOnConsoleKey":true]), "unknown/incomplete session deferred")
var lease = ReplacementLease()
check(lease.valid, "new preview lease valid")
lease.observeActivation(isOwnApp:true)
check(lease.valid, "own window keeps lease")
lease.observeActivation(isOwnApp:false)
check(!lease.valid, "leaving preview invalidates replacement")
lease.observeActivation(isOwnApp:true)
check(!lease.valid, "returning cannot revive old draft")
