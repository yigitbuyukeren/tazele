import Foundation
import Testing
@testable import TazeleCore

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let status = url.path == "/error" ? 404 : 200
        let payload = Data(repeating: 42, count: url.path == "/large" ? 32 : 4)
        let headers = url.path == "/declared" ? ["Content-Length": "100"] : [:]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RedirectCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URLRequest??
    func set(_ request: URLRequest?) { lock.withLock { value = .some(request) } }
    var called: Bool { lock.withLock { value != nil } }
    var request: URLRequest? { lock.withLock { value ?? nil } }
}

@Suite struct BoundedFetchTests {
    private func fetch(_ path: String, limit: Int = 10) async throws -> (Data, URL) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return try await BoundedFetch.data(from: URL(string: "https://example.test\(path)")!, maxBytes: limit,
                                           requestTimeout: 5, resourceTimeout: 5, configuration: config)
    }

    @Test func acceptsBoundedResponse() async throws {
        let (data, url) = try await fetch("/ok")
        #expect(data.count == 4)
        #expect(url.path == "/ok")
    }
    @Test func rejectsOversizedBodyAndBadStatus() async {
        await #expect(throws: BoundedFetch.Failure.tooLarge) { try await fetch("/large") }
        await #expect(throws: BoundedFetch.Failure.tooLarge) { try await fetch("/declared") }
        await #expect(throws: BoundedFetch.Failure.status(404)) { try await fetch("/error") }
    }
    @Test func rejectsHTTPRedirectTarget() {
        #expect(!BoundedDataDelegate.allowsRedirect(to: URL(string: "http://example.test")))
        #expect(BoundedDataDelegate.allowsRedirect(to: URL(string: "https://example.test")))
    }
    @Test func redirectDelegateRejectsDowngrade() throws {
        let secure = try #require(URL(string: "https://example.test/start"))
        let insecure = try #require(URL(string: "http://example.test/next"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: secure)
        let response = try #require(HTTPURLResponse(url: secure, statusCode: 302, httpVersion: nil, headerFields: nil))
        let capture = RedirectCapture()
        BoundedDataDelegate(maxBytes: 10).urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                    newRequest: URLRequest(url: insecure)) { capture.set($0) }
        #expect(capture.called)
        #expect(capture.request == nil)
    }
}
