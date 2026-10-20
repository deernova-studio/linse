import Foundation
import XCTest
@testable import LinseCore

final class FeatureTests: XCTestCase {
    func testXMPIsWellFormed() throws {
        var p = Params()
        p.temperature = 12; p.exposure = -0.456; p.curves.rgb = [[0, 10], [128, 140], [255, 250]]
        p.grading.shadows.hue = 210; p.grading.shadows.sat = 20
        let xml = XMP.make(p, name: "测试 <&>")
        let parser = XMLParser(data: Data(xml.utf8))
        XCTAssertTrue(parser.parse(), "\(parser.parserError?.localizedDescription ?? "")")
        XCTAssertTrue(xml.contains("crs:Exposure2012=\"-0.46\""))
        XCTAssertTrue(xml.contains("crs:IncrementalTemperature=\"+12\""))
        XCTAssertTrue(xml.contains("<rdf:li>128, 140</rdf:li>"))
    }

    func testAIAnalysisClampsAndTolerates() {
        let a = AIAnalysis(json: [
            "style_summary": "冷", "is_portrait": true, "content_not_style": ["a", 3, "b"],
            "params": ["temperature": 400, "exposure": "0.5", "hsl": ["orange": ["sat": -200]], "grading": ["shadows": ["hue": -30, "sat": 90]],
                       "effects": ["grain": 99]],
            "reasons": [["slider": "色温", "why": "偏冷"], "bad"],
        ])
        XCTAssertEqual(a.prior.temperature, 50)
        XCTAssertEqual(a.prior.exposure, 0.5)
        XCTAssertEqual(a.prior.hslValue(.orange).sat, -60)
        XCTAssertEqual(a.prior.grading.shadows.hue, 330)
        XCTAssertEqual(a.prior.grading.shadows.sat, 40)
        XCTAssertEqual(a.prior.effects.grain, 60)
        XCTAssertEqual(a.prior.effects.grainSize, 25)
        XCTAssertEqual(a.isPortrait, true)
        XCTAssertEqual(a.contentNotStyle, ["a", "b"])
        XCTAssertEqual(a.reasons.count, 1)
    }

    func testOpenAIBase() {
        XCTAssertEqual(AIClient.openaiBase(""), "https://api.openai.com/v1")
        XCTAssertEqual(AIClient.openaiBase("https://api.example.com/"), "https://api.example.com/v1")
        XCTAssertEqual(AIClient.openaiBase("https://api.example.com/compat/v1"), "https://api.example.com/compat/v1")
        XCTAssertTrue(AIClient.urlOK(""))
        XCTAssertFalse(AIClient.urlOK("api.example.com"))
    }

    func testLutStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linse-lut-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("in.cube")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var t = "LUT_3D_SIZE 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { t += "\(r) \(g) \(b)\n" } } }
        try t.write(to: src, atomically: true, encoding: .utf8)
        let store = LutStore(dir: dir.appendingPathComponent("luts"))
        let l = try store.importFile(src)
        XCTAssertEqual(l.name, "in")
        let again = LutStore(dir: dir.appendingPathComponent("luts"))
        XCTAssertEqual(again.list.map(\.name), ["in"])
        try again.delete(l.id)
        XCTAssertTrue(LutStore(dir: dir.appendingPathComponent("luts")).list.isEmpty)
    }

    /// 需要本地模拟接口：LINSE_MOCK_AI=http://127.0.0.1:端口
    func testAIClientAgainstMock() async throws {
        guard let base = ProcessInfo.processInfo.environment["LINSE_MOCK_AI"] else { throw XCTSkip("没有模拟接口") }
        var s = AISettings()
        s.proto = .anthropic
        s.model = s.proto.defaultModel
        s.baseUrl = base
        s.effort = .high
        let models = try await AIClient.listModels(s, key: "k")
        XCTAssertEqual(models, ["claude-opus-5-5", "claude-sonnet-5-5"])
        let reply = try await AIClient.test(s, key: "k")
        XCTAssertEqual(reply, "连通")
        s.proto = .openai
        await XCTAssertThrowsErrorAsync(try await AIClient.test(s, key: ""))
    }
}

func XCTAssertThrowsErrorAsync<T>(_ e: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await e(); XCTFail("应当抛错", file: file, line: line) } catch {}
}
