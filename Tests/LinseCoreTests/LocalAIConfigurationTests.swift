import Foundation
import LinseCore
import XCTest

final class LocalAIConfigurationTests: XCTestCase {
    func testMissingConfigurationUsesDefaultsWithoutCreatingFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalAIConfigurationStore(url: directory.appendingPathComponent("config.json"),
                                              legacySettingsURL: directory.appendingPathComponent("old.json"))
        XCTAssertEqual(try store.load(), LocalAIConfiguration())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRoundTripStoresPlainJSONWithOwnerOnlyPermissions() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let store = LocalAIConfigurationStore(url: url)
        let settings = sampleSettings()
        try store.save(settings: settings, key: "test-only-local-key")

        XCTAssertEqual(try LocalAIConfigurationStore(url: url).load(),
                       LocalAIConfiguration(ai: settings, apiKey: "test-only-local-key"))
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["apiKey"] as? String, "test-only-local-key")
        XCTAssertEqual((json["ai"] as? [String: Any])?["baseUrl"] as? String, settings.baseUrl)
        XCTAssertEqual(try permissions(of: directory), 0o700)
        XCTAssertEqual(try permissions(of: url), 0o600)
    }

    func testLegacySettingsArePreservedAndNewConfigurationTakesPrecedence() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("ai-settings.json")
        let legacyData = try JSONEncoder().encode(sampleSettings())
        try legacyData.write(to: legacy)
        let store = LocalAIConfigurationStore(url: directory.appendingPathComponent(".linse/config.json"),
                                              legacySettingsURL: legacy)
        let imported = try store.load()
        XCTAssertEqual(imported.ai, sampleSettings())
        XCTAssertTrue(imported.apiKey.isEmpty)

        var next = imported.ai
        next.model = "new-model"
        try store.save(settings: next, key: "new-local-key")
        XCTAssertEqual(try store.load(), LocalAIConfiguration(ai: next, apiKey: "new-local-key"))
        XCTAssertEqual(try Data(contentsOf: legacy), legacyData, "旧设置保留，便于回退")
    }

    func testEditingSettingsKeepsKeyUntilExplicitlyReplacedOrCleared() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalAIConfigurationStore(url: directory.appendingPathComponent("config.json"))
        try store.save(settings: AISettings(), key: "first-test-key")
        try store.save(settings: sampleSettings(), key: nil)
        XCTAssertEqual(try store.load(), LocalAIConfiguration(ai: sampleSettings(), apiKey: "first-test-key"))
        try store.save(settings: sampleSettings(), key: "replacement-test-key")
        XCTAssertEqual(try store.load().apiKey, "replacement-test-key")
        try store.save(settings: sampleSettings(), key: "")
        XCTAssertTrue(try store.load().apiKey.isEmpty)
        XCTAssertEqual(try permissions(of: store.url), 0o600, "重复保存后文件权限不变")
    }

    func testMalformedConfigurationIsReportedAndNeverOverwritten() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LocalAIConfigurationStore(url: directory.appendingPathComponent("config.json"))
        for content in ["not-json", #"{"apiKey":42}"#, #"{"ai":[]}"#] {
            let damaged = Data(content.utf8)
            try damaged.write(to: store.url)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(settings: AISettings(), key: "replacement-test-key"))
            XCTAssertEqual(try Data(contentsOf: store.url), damaged)
        }
    }

    func testManuallyWrittenPartialConfigurationUsesSettingDefaults() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LocalAIConfigurationStore(url: directory.appendingPathComponent("config.json"))
        try Data(#"{"ai":{"protocol":"anthropic"},"apiKey":"manual-test-key"}"#.utf8).write(to: store.url)
        let configuration = try store.load()
        XCTAssertEqual(configuration.ai.proto, .anthropic)
        XCTAssertEqual(configuration.ai.model, AIProtocol.anthropic.defaultModel)
        XCTAssertEqual(configuration.ai.effort, .auto)
        XCTAssertEqual(configuration.apiKey, "manual-test-key")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("linse-local-config-\(UUID().uuidString)")
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func sampleSettings() -> AISettings {
        var settings = AISettings()
        settings.proto = .anthropic
        settings.baseUrl = "https://example.invalid/v1"
        settings.model = "sample-vision-model"
        settings.effort = .high
        settings.fast = true
        return settings
    }
}
