import Foundation
import CoreGraphics

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if !condition() { fatalError("FAIL: \(name)") }
    print("PASS: \(name)")
}
func rejects(_ name: String, _ block: () throws -> Void) {
    do { try block(); fatalError("FAIL: \(name)") } catch { print("PASS: \(name)") }
}
let normal = Data(#"{"ambiguous":false,"question":"","options":[{"english":"Could you send it tomorrow?","chinese":"你能明天发给我吗？"},{"english":"Would you mind sending it tomorrow?","chinese":"能麻烦你明天发给我吗？"}]}"#.utf8)
let decodedNormal = try PolishResult.decode(normal)
check(decodedNormal.options.count == 2, "exactly two natural alternatives")
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
let p = Placement.buttonRect(axRect:CGRect(x:100,y:200,width:10,height:20), composerRect:CGRect(x:80,y:180,width:500,height:60), primaryHeight:900, visible:CGRect(x:0,y:0,width:1440,height:900))
check(p.minX == 116 && p.maxY == 656 && p.width == 26, "trigger is fully below the composer")
let edge = Placement.buttonRect(axRect:CGRect(x:1430,y:880,width:10,height:20), composerRect:CGRect(x:900,y:850,width:540,height:50), primaryHeight:900, visible:CGRect(x:0,y:0,width:1440,height:900))
check(edge.maxX <= 1434 && edge.minY >= 6, "button stays on screen")
let visibleScreen = CGRect(x:0,y:0,width:1440,height:900)
check(Placement.shouldOpenCandidatesBelow(anchor:CGRect(x:600,y:420,width:26,height:26),visible:visibleScreen), "candidate opens downward when there is room")
check(Placement.shouldOpenCandidatesBelow(anchor:CGRect(x:600,y:197,width:26,height:26),visible:visibleScreen), "candidate uses available lower screen space")
check(!Placement.shouldOpenCandidatesBelow(anchor:CGRect(x:600,y:70,width:26,height:26),visible:visibleScreen), "candidate opens upward near screen bottom")
let belowRect=Placement.candidateRect(anchor:CGRect(x:600,y:300,width:26,height:26),contentSize:CGSize(width:374,height:190),visible:visibleScreen,opensBelow:true)
check(belowRect.maxY < 300,"downward candidate stays physically below trigger")
let aboveRect=Placement.candidateRect(anchor:CGRect(x:600,y:70,width:26,height:26),contentSize:CGSize(width:374,height:190),visible:visibleScreen,opensBelow:false)
check(aboveRect.minY > 96,"upward candidate stays physically above trigger")
let config = APIConfiguration(endpoint:"https://example.com/v1", model:"test-model", key:"test-secret")
let request = try APIClient.makeRequest(text:"I is here", configuration:config)
check(request.url?.absoluteString == "https://example.com/v1/chat/completions", "API URL")
check(request.value(forHTTPHeaderField:"Authorization") == "Bearer test-secret", "authentication header")
let body = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
check(body["model"] as? String == "test-model", "configured model used")
check((body["messages"] as! [[String:Any]]).count == 2, "only instructions and current draft sent")
let systemPrompt = ((body["messages"] as! [[String:Any]]).first?["content"] as? String) ?? ""
check(systemPrompt.contains("common contractions"), "first option requests casual contractions")
check(systemPrompt.contains("Formal written English"), "second option requests formal writing")
let customRequest = try APIClient.makeRequest(text:"Hello",configuration:APIConfiguration(endpoint:"https://example.com/v1",model:"test-model",key:"test-secret",casualPrompt:"Use Malaysian English.",formalPrompt:"Use legal English."))
let customBody = try JSONSerialization.jsonObject(with:customRequest.httpBody!) as! [String:Any]
let customSystemPrompt = ((customBody["messages"] as! [[String:Any]]).first?["content"] as? String) ?? ""
check(customSystemPrompt.contains("Use Malaysian English") && customSystemPrompt.contains("Return ONLY a JSON object"), "custom style prompt keeps output safeguards")
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
check(FloatingButtonStatus.accessibilityNeeded.menuTitle == "轻语：需要辅助功能权限", "permission status is actionable")
check(FloatingButtonStatus.whatsAppNotActive.menuTitle == "轻语：请先切换到 WhatsApp", "frontmost status is actionable")
check(FloatingButtonStatus.emptyDraft.menuTitle == "轻语：输入英文后显示 ✨", "empty draft status is actionable")
