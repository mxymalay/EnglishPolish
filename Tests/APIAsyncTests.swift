import Foundation

final class StubProtocol: URLProtocol {
    static let lock = NSLock()
    static var stopped = false
    static var delay: TimeInterval = 0
    static var status = 200
    var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let job = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let json = #"{"ambiguous":false,"question":"","options":[{"english":"I am here.","chinese":"我在这里。"},{"english":"I'm here.","chinese":"我在这里。"}]}"#
            let data = try! JSONSerialization.data(withJSONObject:["choices":[["finish_reason":"stop","message":["content":json]]]])
            self.client?.urlProtocol(self,didReceive:HTTPURLResponse(url:self.request.url!,statusCode:Self.status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
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
        StubProtocol.status = 503
        do {
            _ = try await APIClient(session:transport).polish("I is here",configuration:config)
            fatalError("HTTP 503 accepted")
        } catch { precondition(error.localizedDescription.contains("503")) }
        print("PASS: async HTTP service failure surfaces")
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
