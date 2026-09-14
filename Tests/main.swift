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
let extraOptions = Data(#"{"ambiguous":false,"question":"","options":[{"english":"one","chinese":"一"},{"english":"two","chinese":"二"},{"english":"three","chinese":"三"}]}"#.utf8)
let decodedExtra = try PolishResult.decode(extraOptions)
check(decodedExtra.options.count == 2 && decodedExtra.options[1].english == "two", "extra model alternatives are capped at two")
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
let p = Placement.buttonRect(axRect:CGRect(x:100,y:200,width:10,height:20), composerRect:CGRect(x:80,y:180,width:500,height:60), sendRect:CGRect(x:590,y:186,width:32,height:32), primaryHeight:900, visible:CGRect(x:0,y:0,width:1440,height:900))
check(abs(p.midX - 606) < 0.5 && p.minY == 900-186+12 && p.width == 26, "trigger stacks directly above the send button")
let fallback = Placement.buttonRect(axRect:CGRect(x:100,y:200,width:10,height:20), composerRect:CGRect(x:80,y:180,width:500,height:60), sendRect:nil, primaryHeight:900, visible:CGRect(x:0,y:0,width:1440,height:900))
check(fallback.minX == 592 && fallback.minY == 900-200+12, "fallback sits right of the composer above the send area")
let edge = Placement.buttonRect(axRect:CGRect(x:1430,y:880,width:10,height:20), composerRect:CGRect(x:900,y:850,width:540,height:50), sendRect:nil, primaryHeight:900, visible:CGRect(x:0,y:0,width:1440,height:900))
check(edge.maxX <= 1434 && edge.minY >= 6, "button stays on screen")
let tall = Placement.buttonRect(axRect:CGRect(x:100,y:400,width:10,height:20), composerRect:CGRect(x:80,y:300,width:500,height:300), sendRect:CGRect(x:590,y:300,width:50,height:300), primaryHeight:900, visible:CGRect(x:0,y:0,width:1440,height:900))
check(abs(tall.midX - 615) < 0.5 && tall.minY == 900-600+40+12, "grown send frame still anchors the trigger at the composer's bottom corner")
let visibleScreen = CGRect(x:0,y:0,width:1440,height:900)
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
check(body["max_tokens"] as? Int == 2048, "bounded completion length")
check((body["temperature"] as? Double) == 0.2, "stable low temperature")
check((body["chat_template_kwargs"] as? [String:Any])?["enable_thinking"] as? Bool == false, "local thinking disabled")
check((body["messages"] as! [[String:Any]]).count == 2, "only instructions and current draft sent")
let systemPrompt = ((body["messages"] as! [[String:Any]]).first?["content"] as? String) ?? ""
check(systemPrompt.contains("common contractions"), "first option requests casual contractions")
check(systemPrompt.contains("Formal written English"), "second option requests formal writing")
let customRequest = try APIClient.makeRequest(text:"Hello",configuration:APIConfiguration(endpoint:"https://example.com/v1",model:"test-model",key:"test-secret",casualPrompt:"Use Malaysian English.",formalPrompt:"Use legal English."))
let customBody = try JSONSerialization.jsonObject(with:customRequest.httpBody!) as! [String:Any]
let customSystemPrompt = ((customBody["messages"] as! [[String:Any]]).first?["content"] as? String) ?? ""
check(customSystemPrompt.contains("Use Malaysian English") && customSystemPrompt.contains("Return ONLY a JSON object"), "custom style prompt keeps output safeguards")
rejects("HTTP endpoint rejected") { _ = try APIClient.makeRequest(text:"Hi",configuration:APIConfiguration(endpoint:"http://example.com/v1",model:"x",key:"y")) }
let localProxyRequest = try APIClient.makeRequest(text:"Hi",configuration:APIConfiguration(endpoint:"http://127.0.0.1:8317/v1",model:"local-model",key:"local-key"))
check(localProxyRequest.url?.absoluteString == "http://127.0.0.1:8317/v1/chat/completions", "local HTTP proxy endpoint allowed")
rejects("missing key rejected") { _ = try APIClient.makeRequest(text:"Hi",configuration:APIConfiguration(endpoint:"https://example.com/v1",model:"x",key:"")) }
rejects("empty draft rejected") { _ = try APIClient.makeRequest(text:"  ",configuration:config) }
let envelope = try JSONSerialization.data(withJSONObject:["choices":[["finish_reason":"stop","message":["content":String(data:normal,encoding:.utf8)!]]]])
let parsedEnvelope = try APIClient.parse(data:envelope,status:200)
check(parsedEnvelope.options.first?.english == "Could you send it tomorrow?", "real response envelope parsed")
let fenced = try JSONSerialization.data(withJSONObject:["choices":[["message":["content":"```json\n\(String(data:normal,encoding:.utf8)!)\n```"]]]])
let parsedFenced = try APIClient.parse(data:fenced,status:200)
check(parsedFenced.options.count == 2, "markdown-wrapped local JSON parsed")
rejects("HTTP failure not accepted") { _ = try APIClient.parse(data:envelope,status:401) }
let truncatedContent = #"{"ambiguous":false,"question":"","options":["#
let truncated = try JSONSerialization.data(withJSONObject:["choices":[["finish_reason":"length","message":["content":truncatedContent]]]])
rejects("truncated generation rejected") { _ = try APIClient.parse(data:truncated,status:200) }
let mislabeledComplete = try JSONSerialization.data(withJSONObject:["choices":[["finish_reason":"length","message":["content":String(data:normal,encoding:.utf8)!]]]])
let parsedMislabeled = try APIClient.parse(data:mislabeledComplete,status:200)
check(parsedMislabeled.options.count == 2, "complete JSON accepted despite gateway length label")
func plainEnvelope(_ content: String, finish: String = "stop") throws -> Data {
    try JSONSerialization.data(withJSONObject:["choices":[["finish_reason":finish,"message":["content":content]]]])
}
let twoLines = "I'd like to add the dataset. What's the safest way?\nI would like to add the dataset. What is the safest approach?"
let plainResult = try APIClient.parse(data:plainEnvelope(twoLines),status:200,allowPlain:true)
check(plainResult.options.map(\.english) == twoLines.components(separatedBy:"\n"), "unnumbered retry preserves both complete sentences")
let numberedResult = try APIClient.parse(data:plainEnvelope("1. Hello.\n2. Good morning."),status:200,allowPlain:true)
check(numberedResult.options.map(\.english) == ["Hello.","Good morning."], "numbered retry strips only ordered markers")
rejects("truncated plain reply rejected") { _ = try APIClient.parse(data:plainEnvelope(twoLines,finish:"length"),status:200,allowPlain:true) }
rejects("extra plain explanation rejected") { _ = try APIClient.parse(data:plainEnvelope("Here are your options:\n"+twoLines),status:200,allowPlain:true) }
rejects("duplicate numbered candidates rejected") { _ = try APIClient.parse(data:plainEnvelope("1. Hello\n1. Hi"),status:200,allowPlain:true) }
rejects("broken JSON cannot become plain candidates") { _ = try APIClient.parse(data:plainEnvelope("{\n\"options\": ["),status:200,allowPlain:true) }
rejects("normal JSON protocol does not accept plain text") { _ = try APIClient.parse(data:plainEnvelope(twoLines),status:200) }
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

// MARK: hover translation
let dmIncoming = BubbleDescription.parse("‎消息, what are you doing, 上午3:12, ‎从バカb莹收到")
check(dmIncoming?.body == "what are you doing", "DM incoming parsed")
let dmOwn = BubbleDescription.parse("‎你的消息, 1, 年1月23日下午9:03, ‎已发送到バカb莹, ‎已送达")
check(dmOwn == nil, "DM own skipped")
let groupIncoming = BubbleDescription.parse("‎可能是Hassan发来的消息, Like the arrow for the other categories, 上午12:29, ‎在FIT5120 TM1")
check(groupIncoming?.body == "Like the arrow for the other categories", "group sender prefix stripped")
let maskedSender = BubbleDescription.parse("‎可能是..发来的消息, I will fix that, 上午12:29")
check(maskedSender?.body == "I will fix that" && maskedSender?.incoming == true, "masked sender group message parsed")
check(BubbleDescription.parse("‎正在回复‎可能 Hassan.") == nil, "quoted reply without exposed body skipped")
check(BubbleDescription.parse("‎可能是Hassan发来的照片, 上午12:29, ‎在FIT5120 TM1") == nil, "photo bubbles skipped")
let photoCaption = BubbleDescription.parse("‎可能是Hassan发来的照片, see the caption, 上午12:29, ‎在FIT5120 TM1")
check(photoCaption?.body == "see the caption" && photoCaption?.kind == .media && photoCaption?.kind.canTranslate == false, "media caption has no translation action")
let incomingFile = BubbleDescription.parse("‎可能是Hassan发来的文件, design-notes.pdf, 1.2 MB, 上午12:29, ‎在FIT5120 TM1")
check(incomingFile?.body == "design-notes.pdf" && incomingFile?.kind == .file && incomingFile?.kind.canTranslate == false && incomingFile?.incoming == true, "incoming file has no translation action")
let incomingDocument = BubbleDescription.parse("‎可能是Hassan发来的文档, Here are the slides, TM015_IMShowcase_Iteration1.pdf, 11页, 上午12:29, ‎在FIT5120 TM1")
check(incomingDocument?.kind == .media && incomingDocument?.incoming == true, "incoming document uses media placement")
check(BubbleDescription.parse("‎你的文件, design-notes.pdf, 已发送到Hassan, ‎已送达") == nil, "outgoing file skipped")
let sharedLink = BubbleDescription.parse("‎xinhui发来的消息, 链接，https://teams.microsoft.com/l/message/123，Join conversation, 年9月7日中午12:02, ‎在FIT5120 TM15收到")
check(sharedLink?.kind == .link && sharedLink?.kind.canTranslate == false && sharedLink?.incoming == true, "shared link has no translation action")
let captionText = BubbleDescription.parse("‎消息, your photo, 上午12:29, ‎从Hassan收到")
check(captionText?.kind == .text && captionText?.incoming == true && captionText?.kind.canTranslate == true, "text bubbles remain translatable")
let textSlot = MessageHoverPlacement.buttonRect(bubble:CGRect(x:100,y:200,width:200,height:40),visible:CGRect(x:0,y:0,width:1000,height:800),systemActionCount:1)
check(textSlot.minX == 348 && textSlot.midY == 220, "text hover action uses the second slot")
let fileSlot = MessageHoverPlacement.buttonRect(bubble:CGRect(x:100,y:200,width:200,height:40),visible:CGRect(x:0,y:0,width:1000,height:800),systemActionCount:2)
check(fileSlot.minX == 388 && fileSlot.midY == 220, "file hover action uses the third slot")
let mediaSlot = MessageHoverPlacement.buttonRect(bubble:CGRect(x:100,y:200,width:200,height:40),visible:CGRect(x:0,y:0,width:1000,height:800),systemActionCount:2)
check(mediaSlot.minX == 388 && mediaSlot.midY == 220, "media hover action uses the third slot")
let mediaContentSlot = MessageHoverPlacement.buttonRect(bubble:CGRect(x:100,y:160,width:200,height:120),visible:CGRect(x:0,y:0,width:1000,height:800),systemActionCount:2,verticalAnchor:CGRect(x:120,y:190,width:160,height:40))
check(mediaContentSlot.midY == 210, "media hover action follows the attachment center")
let mirrored = MessageHoverPlacement.buttonRect(bubble:CGRect(x:700,y:200,width:250,height:40),visible:CGRect(x:0,y:0,width:1000,height:800),systemActionCount:2)
check(mirrored.maxX < 700, "media hover action mirrors at screen edge")
check(BubbleDescription.parse("‎消息, 明天下午3点来我家, 年9月11日下午5:50, ‎从xinhui收到")?.body == "明天下午3点来我家", "body with time words survives")
let channelPost = BubbleDescription.parse("‎消息, channel post body, 上午9:00")
check(channelPost?.body == "channel post body", "tailless description treated as incoming")
check(BubbleDescription.parse("‎你的消息, hi, 上午9:00") == nil, "own marker without delivery tail is skipped")
check(BubbleDescription.parse("") == nil && BubbleDescription.parse("消息") == nil, "empty description rejected")
let replyDescription = """
\u{200E}正在回复可能 Hassan.
可能是..发来的消息, Good night. Thank you for your effort brother, 凌晨3:30, 在FIT5120 TM15 🪦收到.
引用消息.
yep took me 6+ hours
"""
let replyOwn = BubbleDescription.replyOwnDescription(replyDescription)
check(replyOwn?.hasPrefix("可能是..发来的消息") == true, "reply own description extracted from quoted bubble")
check(BubbleDescription.parse(replyOwn ?? "")?.body == "Good night. Thank you for your effort brother", "reply body parsed for translation")
check(BubbleDescription.replyOwnDescription("消息, plain message, 上午9:00") == nil, "non-reply descriptions untouched")
check(BubbleDescription.parse("‎可能是Bob发来的消息, meeting moved, 星期四下午3:00, ‎在FIT5120 TM1")?.body == "meeting moved", "weekday timestamps stripped")
check(BubbleDescription.parse("‎消息, see you there, 周四 14:22, ‎从xinhui收到")?.body == "see you there", "weekday plus clock time stripped")
check(BubbleDescription.parse("‎可能是Bob发来的消息, 凌晨1点见, 上午1:15, ‎在FIT5120 TM1")?.body == "凌晨1点见", "time words inside the body survive")
