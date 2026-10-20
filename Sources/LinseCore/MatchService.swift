import CoreImage
import Foundation
import Metal

public struct MatchResult: Sendable {
    public let params: Params
    public let summary: MatchSummary
    public let analysis: AIAnalysis?
    public let seconds: Double
}

/// 每次请求独占渲染器；AI 网络等待允许 actor 重入，但请求之间不共享可变 GPU 状态。
public actor MatchService {
    public typealias Analyze = @Sendable (AISettings, String, AIImages) async throws -> AIAnalysis
    private let device: MTLDevice
    private let analyze: Analyze

    public init(device: MTLDevice, analyze: @escaping Analyze = { try await AIClient.analyze($0, key: $1, images: $2) }) {
        self.device = device
        self.analyze = analyze
    }

    public func match(source: CIImage, target: CIImage, ai: AISettings? = nil, key: String = "",
                      progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> MatchResult {
        try Task.checkCancellation()
        let started = Date()
        let renderer = try Renderer(device: device)
        func measure(_ image: CIImage) throws -> ImageStats {
            try renderer.setImage(ci: image, maxSide: 320)
            let width = Int(renderer.imageSize.width), height = Int(renderer.imageSize.height)
            let pixels = try renderer.renderRGBA8(Params(), width: width, height: height, opts: RenderOptions(bypass: true))
            return Stats.compute(pixels, weights: Stats.detailWeights(pixels, width: width))
        }

        var analysis: AIAnalysis?
        if let ai {
            let stats = ["source": AIAnalysis.statsJSON(try measure(source)), "target": AIAnalysis.statsJSON(try measure(target))]
            let images = AIImages(source: try Self.jpegBase64(source, renderer.ciContext),
                                  target: try Self.jpegBase64(target, renderer.ciContext),
                                  stats: try JSONSerialization.data(withJSONObject: stats, options: [.sortedKeys]))
            analysis = try await analyze(ai, key, images)
            try Task.checkCancellation()
            progress("分析目标照片…")
        }
        let targetStats = try measure(target)
        try renderer.setImage(ci: source, maxSide: 320)
        try Task.checkCancellation()
        let label = analysis == nil ? "正在对齐" : "按 AI 初值精确对齐"
        let (params, summary) = try Estimator.match(renderer, target: targetStats,
            options: MatchOptions(prior: analysis?.prior, portraitHint: analysis?.isPortrait,
                                  onProgress: { progress("\(label)：\($0)") }))
        try Task.checkCancellation()
        return MatchResult(params: params, summary: summary, analysis: analysis, seconds: Date().timeIntervalSince(started))
    }

    private static func jpegBase64(_ image: CIImage, _ context: CIContext) throws -> String {
        let scale = min(1, 1024 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).settingProperties([:])
        guard let data = context.jpegRepresentation(of: small, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9])
        else { throw AIError("图片编码失败") }
        return data.base64EncodedString()
    }
}
