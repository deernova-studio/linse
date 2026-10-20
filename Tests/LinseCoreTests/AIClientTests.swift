import Foundation
import XCTest
@testable import LinseCore

final class AIClientTests: XCTestCase {
    private func settings(_ endpoint: MockAIEndpoint, fast: Bool = false) -> AISettings {
        var settings = AISettings()
        settings.baseUrl = endpoint.baseURL
        settings.fast = fast
        return settings
    }

    private func completion(_ text: String = "连通", finish: String = "stop") -> [String: Any] {
        ["choices": [["message": ["role": "assistant", "content": text], "finish_reason": finish]]]
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testOpenAIFastRequestUsesModernTokenBudgetAndPreservesReasoning() async throws {
        let endpoint = try MockAIEndpoint([(200, completion())])
        defer { endpoint.close() }
        var s = settings(endpoint, fast: true)
        s.effort = .xhigh
        let reply = try await AIClient.test(s, key: "test-only-key", session: endpoint.session)
        XCTAssertEqual(reply, "连通")
        XCTAssertEqual(endpoint.requests.count, 1)
        let request = try XCTUnwrap(endpoint.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-key")
        let payload = try body(request)
        XCTAssertEqual(payload["model"] as? String, "gpt-5.5")
        XCTAssertEqual(payload["max_completion_tokens"] as? Int, 1024)
        XCTAssertNil(payload["max_tokens"])
        XCTAssertEqual(payload["service_tier"] as? String, "priority")
        XCTAssertEqual(payload["reasoning_effort"] as? String, "xhigh")
        XCTAssertNil(payload["speed"])
    }

    func testDefaultRequestDoesNotEnablePaidPriorityOrOverrideReasoning() async throws {
        let endpoint = try MockAIEndpoint([(200, completion())])
        defer { endpoint.close() }
        _ = try await AIClient.test(settings(endpoint), key: "test-only-key", session: endpoint.session)
        let payload = try body(XCTUnwrap(endpoint.requests.first))
        XCTAssertNil(payload["service_tier"])
        XCTAssertNil(payload["reasoning_effort"])
    }

    func testLegacyTokenFieldFallbackPreservesSelectedOptions() async throws {
        let endpoint = try MockAIEndpoint([
            (400, ["error": ["message": "Unrecognized request argument supplied: max_completion_tokens"]]),
            (200, completion()),
        ])
        defer { endpoint.close() }
        var s = settings(endpoint, fast: true)
        s.effort = .xhigh
        _ = try await AIClient.test(s, key: "test-only-key", session: endpoint.session)
        XCTAssertEqual(endpoint.requests.count, 2)
        let original = try body(endpoint.requests[0]), fallback = try body(endpoint.requests[1])
        XCTAssertNotNil(original["max_completion_tokens"])
        XCTAssertNil(original["max_tokens"])
        XCTAssertNil(fallback["max_completion_tokens"])
        XCTAssertEqual(fallback["max_tokens"] as? Int, 1024)
        XCTAssertEqual(fallback["service_tier"] as? String, "priority")
        XCTAssertEqual(fallback["reasoning_effort"] as? String, "xhigh")
    }

    func testModelListingCanSucceedWhileInferenceReturns502() async throws {
        let endpoint = try MockAIEndpoint([
            (200, ["data": [["id": "gpt-5.5"]]]),
            (502, ["error": ["message": "Upstream service temporarily unavailable"]]),
        ])
        defer { endpoint.close() }
        let s = settings(endpoint)
        let models = try await AIClient.listModels(s, key: "test-only-key", session: endpoint.session)
        XCTAssertEqual(models, ["gpt-5.5"])
        do {
            _ = try await AIClient.test(s, key: "test-only-key", session: endpoint.session)
            XCTFail("模型列表可用不能使推理请求的 502 被当作连通")
        } catch let error as AIError {
            XCTAssertEqual(error.status, 502)
            XCTAssertTrue(error.message.contains("上游模型暂时不可用"))
            XCTAssertTrue(error.message.contains(endpoint.host))
            XCTAssertTrue(error.message.contains("Upstream service temporarily unavailable"))
        }
        XCTAssertEqual(endpoint.requests.count, 2, "网关错误不重试")
        XCTAssertEqual(endpoint.requests.map { $0.url?.path }, ["/v1/models", "/v1/chat/completions"])
    }

    func testPriorityRejectionDoesNotSilentlyDowngradeOrRetryImageAnalysis() async throws {
        let endpoint = try MockAIEndpoint([(400, ["error": ["message": "Unsupported parameter: service_tier"]])])
        defer { endpoint.close() }
        do {
            _ = try await AIClient.analyze(settings(endpoint, fast: true), key: "test-only-key",
                                           images: AIImages(source: "test-source", target: "test-target", stats: nil), session: endpoint.session)
            XCTFail("优先处理被拒绝应显示错误")
        } catch let error as AIError {
            XCTAssertEqual(error.status, 400)
            XCTAssertTrue(error.message.contains("service_tier"))
        }
        XCTAssertEqual(endpoint.requests.count, 1)
    }

    func testStructuredOutputFallbackKeepsImagesAndFastMode() async throws {
        let endpoint = try MockAIEndpoint([
            (422, ["error": ["message": "response_format json_schema is not supported"]]),
            (200, completion("{\"style_summary\":\"暖色\",\"params\":{\"exposure\":0.5}}")),
        ])
        defer { endpoint.close() }
        let analysis = try await AIClient.analyze(settings(endpoint, fast: true), key: "test-only-key",
                                                  images: AIImages(source: "test-source", target: "test-target", stats: nil), session: endpoint.session)
        XCTAssertEqual(analysis.prior.exposure, 0.5)
        XCTAssertEqual(endpoint.requests.count, 2)
        let original = try body(endpoint.requests[0]), fallback = try body(endpoint.requests[1])
        XCTAssertNotNil(original["response_format"])
        XCTAssertNil(fallback["response_format"])
        XCTAssertEqual(fallback["service_tier"] as? String, "priority")
        XCTAssertEqual(fallback["max_completion_tokens"] as? Int, 16000)
        XCTAssertTrue(NSDictionary(dictionary: ["messages": original["messages"]!]).isEqual(to: ["messages": fallback["messages"]!]))
        let messages = try XCTUnwrap(fallback["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(content.filter { $0["type"] as? String == "image_url" }.count, 2)
    }

    func testEmptyTruncatedAndWrongEndpointRepliesDoNotPassConnectionTest() async throws {
        let samples: [([String: Any], String)] = [
            (completion("  \n"), "没有返回有效文字"),
            (completion("部分回复", finish: "length"), "输出长度限制"),
            (["output": [["type": "message"]]], "未返回聊天结果"),
            (["choices": [["message": ["refusal": "refused"]]]], "拒绝"),
        ]
        for (payload, expected) in samples {
            let endpoint = try MockAIEndpoint([(200, payload)])
            defer { endpoint.close() }
            do {
                _ = try await AIClient.test(settings(endpoint), key: "test-only-key", session: endpoint.session)
                XCTFail("无效结果不得显示已连通")
            } catch let error as AIError {
                XCTAssertTrue(error.message.contains(expected), error.message)
            }
            XCTAssertEqual(endpoint.requests.count, 1)
        }
    }

    func testAnthropicFastModeStillUsesItsOwnProtocol() async throws {
        let endpoint = try MockAIEndpoint([(200, ["content": [["type": "text", "text": "连通"]], "stop_reason": "end_turn"])])
        defer { endpoint.close() }
        var s = AISettings()
        s.proto = .anthropic
        s.model = s.proto.defaultModel
        s.baseUrl = "https://\(endpoint.host)"
        s.fast = true
        s.effort = .high
        _ = try await AIClient.test(s, key: "test-only-key", session: endpoint.session)
        let request = try XCTUnwrap(endpoint.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-only-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "fast-mode-2026-02-01")
        let payload = try body(request)
        XCTAssertEqual(payload["max_tokens"] as? Int, 1024)
        XCTAssertEqual(payload["speed"] as? String, "fast")
        XCTAssertNil(payload["service_tier"])
        XCTAssertNil(payload["max_completion_tokens"])
    }
}
