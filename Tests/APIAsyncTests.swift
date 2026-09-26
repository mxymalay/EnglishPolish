import Foundation

final class StubProtocol: URLProtocol {
    static let lock = NSLock()
    static var stopped = false
    static var delay: TimeInterval = 0
    static var status = 200
    static var scripted: [(String, String)] = []
    static var failure: URLError?
    /// 原样返回的响应体，用来模拟 ai-router 的错误信封（不被 choices 包一层）。
    static var raw: Data?
    static var requests: [URLRequest] = []
    var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let job = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Self.requests.append(self.request)
            if let failure = Self.failure {
                self.client?.urlProtocol(self,didFailWithError:failure)
                return
            }
            let response = HTTPURLResponse(url:self.request.url!,statusCode:Self.status,httpVersion:nil,headerFields:nil)!
            if let raw = Self.raw {
                self.client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
                self.client?.urlProtocol(self,didLoad:raw)
                self.client?.urlProtocolDidFinishLoading(self)
                return
            }
            let json = #"{"ambiguous":false,"question":"","options":[{"english":"I am here.","chinese":"我在这里。"},{"english":"I'm here.","chinese":"我在这里。"}]}"#
            let reply = Self.scripted.isEmpty ? ("stop", json) : Self.scripted.removeFirst()
            let data = try! JSONSerialization.data(withJSONObject:["choices":[["finish_reason":reply.0,"message":["content":reply.1]]]])
            self.client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            self.client?.urlProtocol(self,didLoad:data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        work = job
        DispatchQueue.global().asyncAfter(deadline:.now()+Self.delay,execute:job)
    }
    override func stopLoading() {
        work?.cancel()
        Self.lock.lock(); Self.stopped = true; Self.lock.unlock()
    }
}

@main
struct APIAsyncTests {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration:configuration)
    }
    static func main() async throws {
        let config = APIConfiguration(endpoint:"https://offline.test/v1",model:"test",key:"test")
        let transport = session()
        defer { transport.invalidateAndCancel() }
        let result = try await APIClient(session:transport).polish("I is here",configuration:config)
        precondition(result.options.first?.english == "I am here.")
        print("PASS: async transport decodes response (no network)")
        let styled = APIConfiguration(endpoint:config.endpoint,model:config.model,key:config.key,casualPrompt:"Use Malaysian English.",formalPrompt:"Use legal English.")
        for reason in ["length", "stop"] {
            StubProtocol.requests = []
            StubProtocol.scripted = [(reason, "{\"options\":["), ("stop", "I'm busy. Can we talk later?\nI am currently occupied. Could we speak later?")]
            let retried = try await APIClient(session:transport).polish("我现在忙，晚点聊？",configuration:styled)
            precondition(retried.options.count == 2 && retried.options[0].english == "I'm busy. Can we talk later?")
            precondition(StubProtocol.requests.count == 2 && StubProtocol.scripted.isEmpty)
            let retryRequest = try APIClient.makeRequest(text:"我现在忙，晚点聊？",configuration:styled,compact:true)
            let payload = try JSONSerialization.jsonObject(with:retryRequest.httpBody!) as! [String:Any]
            let prompt = (payload["messages"] as! [[String:String]])[0]["content"]!
            precondition(payload["response_format"] == nil && prompt.contains("Use Malaysian English.") && prompt.contains("Use legal English."))
            print("PASS: \(reason) malformed response retries once and accepts unnumbered candidates with custom styles")
        }
        StubProtocol.requests = []
        StubProtocol.scripted = [("length", "{"), ("length", "1. One.\n2. Incomplete")]
        do { _ = try await APIClient(session:transport).polish("Hello",configuration:config); fatalError("truncated retry accepted") }
        catch { precondition(error.localizedDescription.contains("截断")) }
        precondition(StubProtocol.requests.count == 2 && StubProtocol.scripted.isEmpty)
        print("PASS: incomplete retry rejected without further requests")
        StubProtocol.status = 503
        do {
            _ = try await APIClient(session:transport).polish("I is here",configuration:config)
            fatalError("HTTP 503 accepted")
        } catch { precondition(error.localizedDescription.contains("503")) }
        print("PASS: async HTTP service failure surfaces")
        // ai-router 的结构化 503 要把原话透出来，不能被泛化成「请检查服务地址和模型」。
        StubProtocol.status = 503
        StubProtocol.raw = Data(#"{"error":{"type":"router_resource_guard","reason":"resource_guard","message":"资源保护已开启：local-work。已阻止 qwen-fast 请求。","target":"qwen-fast","stage":"received","retry_after":60},"ok":false,"error_message":"资源保护已开启：local-work。已阻止 qwen-fast 请求。"}"#.utf8)
        do {
            _ = try await APIClient(session:transport).polish("I is here",configuration:config)
            fatalError("router 503 accepted")
        } catch {
            let text = error.localizedDescription
            precondition(text.contains("资源保护已开启：local-work") && text.contains("60 秒"), "unexpected reason: \(text)")
        }
        print("PASS: polish shows the router reason verbatim with its retry hint")
        // 翻译以前只有泛化的 HTTP 提示，现在必须给同一个原因。
        StubProtocol.raw = Data(#"{"error":{"reason":"resource_guard","message":"资源保护已开启：local-work。"},"ok":false}"#.utf8)
        do {
            _ = try await APIClient(session:transport).translate("hello",target:APIClient.incomingTarget,configuration:config)
            fatalError("router 503 accepted for translate")
        } catch { precondition(error.localizedDescription.contains("资源保护已开启：local-work"), "unexpected reason: \(error.localizedDescription)") }
        print("PASS: translation shows the same router reason")
        // 没有 message 时用 reason 的封闭集合兜底，也不能退回泛化提示。
        StubProtocol.raw = Data(#"{"error":{"type":"router_model_not_running","reason":"model_not_running"},"ok":false}"#.utf8)
        do {
            _ = try await APIClient(session:transport).polish("I is here",configuration:config)
            fatalError("router 503 accepted without message")
        } catch { precondition(error.localizedDescription.contains("没有在运行"), "unexpected reason: \(error.localizedDescription)") }
        StubProtocol.raw = nil
        print("PASS: a bare router reason still becomes a readable sentence")
        // Router 没跑时给中文原因，而不是系统的 "Could not connect to the server."
        StubProtocol.status = 200
        StubProtocol.failure = URLError(.cannotConnectToHost)
        do {
            _ = try await APIClient(session:transport).polish("I is here",configuration:APIConfiguration(endpoint:"http://127.0.0.1:3211/v1",model:"qwen-fast",key:"x"))
            fatalError("refused connection accepted")
        } catch { precondition(error.localizedDescription.contains("ai-router"), "unexpected reason: \(error.localizedDescription)") }
        StubProtocol.failure = nil
        print("PASS: a refused local connection names ai-router")
        StubProtocol.status = 200; StubProtocol.delay = 2
        let task = Task { try await APIClient(session:transport).polish("I is here",configuration:config) }
        try await Task.sleep(nanoseconds:100_000_000)
        task.cancel()
        do { _ = try await task.value; fatalError("cancelled request accepted") }
        catch { precondition(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        print("PASS: cancellation aborts in-flight request")
        var acceptedRedirect: URLRequest? = URLRequest(url:URL(string:"https://other.test")!)
        let redirectResponse = HTTPURLResponse(url:URL(string:"https://offline.test")!,statusCode:302,httpVersion:nil,headerFields:nil)!
        NoRedirect().urlSession(transport,task:transport.dataTask(with:URL(string:"https://offline.test")!),willPerformHTTPRedirection:redirectResponse,newRequest:acceptedRedirect!) { acceptedRedirect = $0 }
        precondition(acceptedRedirect == nil)
        print("PASS: cross-host redirect denied")
    }
}
