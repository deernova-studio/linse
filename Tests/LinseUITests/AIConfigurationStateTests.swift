#if os(macOS)
import CoreImage
import LinseCore
import Metal
@testable import LinseUI
import XCTest

@MainActor
final class AIConfigurationStateTests: XCTestCase {
    func testSettingsAndLocalKeySurviveNewAppStateAndBlankKeyEdit() throws {
        try requireLocalConfiguration()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalAIConfigurationStore(url: directory.appendingPathComponent(".linse/config.json"))
        let state = makeState(directory, store)
        state.loadAISettings()
        XCTAssertFalse(state.aiHasKey)
        var settings = AISettings()
        settings.baseUrl = " https://example.invalid/v1 "
        settings.model = " test-model "
        try state.saveAISettings(settings, key: "  local-test-key\n")

        let reopened = makeState(directory, store)
        reopened.loadAISettings()
        XCTAssertTrue(reopened.aiHasKey)
        XCTAssertEqual(reopened.aiKey(), "local-test-key")
        XCTAssertEqual(reopened.aiSettings.baseUrl, "https://example.invalid/v1")
        XCTAssertEqual(reopened.aiSettings.model, "test-model")
        var changed = reopened.aiSettings
        changed.fast = true
        try reopened.saveAISettings(changed, key: nil)
        XCTAssertEqual(try store.load().apiKey, "local-test-key")
        XCTAssertEqual(AISettingsView(state: reopened).effectiveKey, "local-test-key")
    }

    func testReadAndSaveFailuresKeepExistingConfigurationAndPublishedState() throws {
        try requireLocalConfiguration()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalAIConfigurationStore(url: directory.appendingPathComponent(".linse/config.json"))
        let state = makeState(directory, store)
        try state.saveAISettings(AISettings(), key: "existing-test-key")
        let damaged = Data("damaged-json".utf8)
        try damaged.write(to: store.url)
        state.loadAISettings()
        XCTAssertTrue(state.toast?.contains("读取 AI 配置失败") == true)
        var changed = AISettings()
        changed.model = "must-not-be-published"
        XCTAssertThrowsError(try state.saveAISettings(changed, key: "replacement-test-key"))
        XCTAssertEqual(state.aiSettings, AISettings())
        XCTAssertEqual(state.aiKey(), "existing-test-key")
        XCTAssertTrue(state.aiHasKey)
        XCTAssertEqual(try Data(contentsOf: store.url), damaged)

        try FileManager.default.removeItem(at: store.url.deletingLastPathComponent())
        try Data("not-a-directory".utf8).write(to: store.url.deletingLastPathComponent())
        XCTAssertThrowsError(try state.saveAISettings(changed, key: nil))
        XCTAssertEqual(state.aiSettings, AISettings())
        XCTAssertEqual(state.aiKey(), "existing-test-key")
    }

    func testMatchingReadsSavedLocalKeyWithoutKeyProviderOrNetwork() async throws {
        try requireLocalConfiguration()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalAIConfigurationStore(url: directory.appendingPathComponent(".linse/config.json"))
        try store.save(settings: AISettings(), key: "local-match-test-key")
        let called = expectation(description: "匹配读取本地 Key")
        let service = MatchService(device: try XCTUnwrap(MTLCreateSystemDefaultDevice())) { _, key, _ in
            XCTAssertEqual(key, "local-match-test-key")
            called.fulfill()
            throw AIError("test-stop-before-network")
        }
        let state = AppState(luts: LutStore(dir: directory.appendingPathComponent("luts")),
                             matchService: service, aiConfigurationStore: store)
        state.loadAISettings()
        state.load(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16)), name: "source", into: .source)
        state.load(CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16)), name: "target", into: .target)
        state.runMatch(useAI: true)
        await state.aiTask?.value
        await fulfillment(of: [called], timeout: 5)
        XCTAssertFalse(state.showAISettings)
        XCTAssertNil(state.busy)
    }

    private func requireLocalConfiguration() throws {
        if ProcessInfo.processInfo.environment["LINSE_AI_KEY"] != nil {
            throw XCTSkip("本地配置测试需要未设置 LINSE_AI_KEY，避免开发环境覆盖本地 Key")
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("linse-ai-state-\(UUID().uuidString)")
    }

    private func makeState(_ directory: URL, _ store: LocalAIConfigurationStore) -> AppState {
        AppState(luts: LutStore(dir: directory.appendingPathComponent("luts")), aiConfigurationStore: store)
    }
}
#endif
