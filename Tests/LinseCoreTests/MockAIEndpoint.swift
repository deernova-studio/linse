import Foundation

/// 每个测试使用独立域名和 URLSession；不访问网络，也不读取用户的 API Key。
final class MockAIEndpoint: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [String: MockAIEndpoint] = [:]
    private let lock = NSLock()
    private var replies: [(Int, Data)]
    private var recorded: [URLRequest] = []
    let host = "\(UUID().uuidString.lowercased()).linse.test"
    let session: URLSession

    var baseURL: String { "https://\(host)/v1" }
    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    init(_ replies: [(Int, [String: Any])]) throws {
        self.replies = try replies.map { ($0.0, try JSONSerialization.data(withJSONObject: $0.1)) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAIURLProtocol.self]
        session = URLSession(configuration: config)
        Self.registryLock.lock()
        Self.registry[host] = self
        Self.registryLock.unlock()
    }

    func close() {
        session.invalidateAndCancel()
        Self.registryLock.lock()
        Self.registry.removeValue(forKey: host)
        Self.registryLock.unlock()
    }

    static func endpoint(for request: URLRequest) -> MockAIEndpoint? {
        registryLock.lock()
        defer { registryLock.unlock() }
        return request.url?.host.flatMap { registry[$0] }
    }

    func reply(to request: URLRequest) throws -> (Int, Data) {
        var copy = request
        if copy.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
                if count == 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            copy.httpBody = data
        }
        lock.lock()
        defer { lock.unlock() }
        recorded.append(copy)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        return replies.removeFirst()
    }
}

private final class MockAIURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let endpoint = MockAIEndpoint.endpoint(for: request), let url = request.url else {
                throw URLError(.unsupportedURL)
            }
            let (status, data) = try endpoint.reply(to: request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
