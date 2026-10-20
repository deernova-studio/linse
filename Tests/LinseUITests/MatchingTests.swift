import CoreImage
import LinseCore
import Metal
@testable import LinseUI
import XCTest

final class MatchingTests: XCTestCase {
    @MainActor
    func testFailedAnalysisPreservesPreviewAndCanMatchAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linse-match-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = MatchService(device: try XCTUnwrap(MTLCreateSystemDefaultDevice())) { _, key, _ in
            XCTAssertEqual(key, "test-only")
            throw AIError("模拟接口失败")
        }
        let state = makeState(directory, service)
        var params = Params()
        params.exposure = 1
        state.applyPreset(Preset(id: "before", name: "before", params: params))
        let before = try state.proxy.renderRGBA8(Params(), width: 64, height: 32)
        state.runMatch(useAI: true)
        state.confirmAIPhotoConsent(try XCTUnwrap(state.aiPhotoConsent).id)
        await state.aiTask?.value
        XCTAssertNil(state.busy)
        XCTAssertTrue(state.toast?.contains("模拟接口失败") == true)
        XCTAssertEqual(state.params, params)
        XCTAssertEqual(state.proxy.imageSize, CGSize(width: 64, height: 32))
        XCTAssertEqual(try state.proxy.renderRGBA8(Params(), width: 64, height: 32), before)

        state.runMatch()
        await state.aiTask?.value
        XCTAssertNil(state.busy)
        XCTAssertNotNil(state.matched)
        XCTAssertEqual(state.summary?.source, "计算匹配")
        let result = state.params
        state.undoAction()
        XCTAssertEqual(state.params, params)
        XCTAssertEqual(state.summary?.source, "预设 · before")
        state.redoAction()
        XCTAssertEqual(state.params, result)
        XCTAssertEqual(state.summary?.source, "计算匹配")
        XCTAssertEqual(state.proxy.imageSize, CGSize(width: 64, height: 32))
        state.load(CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16)), name: "new-target", into: .target)
        state.undoAction()
        state.redoAction()
        XCTAssertEqual(state.summary?.stale, true, "换图后撤销/重做不能重新宣称旧匹配有效")
    }

    @MainActor
    func testCancellationDuringAnalysisNeverChangesPreview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linse-match-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = expectation(description: "分析请求已开始")
        let gate = AnalysisGate()
        let service = MatchService(device: try XCTUnwrap(MTLCreateSystemDefaultDevice())) { _, _, _ in
            await gate.wait { entered.fulfill() }
        }
        let state = makeState(directory, service)
        let before = try state.proxy.renderRGBA8(Params(), width: 64, height: 32)
        state.runMatch(useAI: true)
        state.confirmAIPhotoConsent(try XCTUnwrap(state.aiPhotoConsent).id)
        let task = try XCTUnwrap(state.aiTask)
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(state.proxy.imageSize, CGSize(width: 64, height: 32), "网络等待期间也不能借用预览渲染器")
        state.cancelBusy()
        await gate.release()
        await task.value
        XCTAssertNil(state.busy)
        XCTAssertNil(state.matched)
        XCTAssertEqual(state.toast, "已取消")
        XCTAssertEqual(try state.proxy.renderRGBA8(Params(), width: 64, height: 32), before)
        state.runMatch(useAI: true)
        state.confirmAIPhotoConsent(try XCTUnwrap(state.aiPhotoConsent).id)
        await state.aiTask?.value
        XCTAssertNil(state.busy)
        XCTAssertEqual(state.summary?.source, "AI 辅助匹配")
        XCTAssertNotNil(state.summary?.ai)
        XCTAssertNotNil(state.matched)
    }

    @MainActor
    private func makeState(_ directory: URL, _ service: MatchService) -> AppState {
        let state = AppState(luts: LutStore(dir: directory), matchService: service, aiKeyProvider: { "test-only" })
        state.load(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32)), name: "source", into: .source)
        state.load(CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 64)), name: "target", into: .target)
        state.aiHasKey = true
        return state
    }
}

private actor AnalysisGate {
    private var continuation: CheckedContinuation<AIAnalysis, Never>?
    private var released = false
    func wait(started: @Sendable () -> Void) async -> AIAnalysis {
        if released { return AIAnalysis(json: [:]) }
        return await withCheckedContinuation {
            continuation = $0
            started()
        }
    }
    func release() {
        released = true
        continuation?.resume(returning: AIAnalysis(json: [:]))
        continuation = nil
    }
}
