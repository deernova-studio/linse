// Three real product workflows. No mocks, unit-test framework or test target.
import CoreImage
import Foundation

@main
struct SmokeFlows {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "LinseSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linse-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceBytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: "Fixtures/Electron/source.rgba")))
        guard let sourceImage = Exporter.cgImage(rgba: sourceBytes, width: 64, height: 48) else {
            throw NSError(domain: "LinseSmoke", code: 2)
        }
        let input = directory.appendingPathComponent("source.png")
        try Exporter.write(sourceImage, to: input, format: .png)
        let importer = ImageImportService()
        let source = try await importer.load(input)
        let renderer = try Renderer()
        let exporter = ExportService(device: renderer.device)

        // S1: File import -> actual Metal adjustment -> all supported image exports -> reopen.
        var edits = Params()
        edits.exposure = 0.5
        for format in ExportFormat.allCases {
            let output = directory.appendingPathComponent("edited.\(format.ext)")
            let rendered = try await exporter.writeImage(source.image, params: edits, assets: ExportAssets(params: edits), format: format, to: output)
            let reopened = try await importer.load(output)
            try require(reopened.image.extent.width == 64 && reopened.image.extent.height == 48, "S1: exported dimensions changed")
            try require((try Data(contentsOf: output)).count > 0, "S1: empty export")
            if format == .tiff16 { try require(rendered.bitsPerComponent == 16, "S1: lost TIFF precision") }
        }
        print("PASS S1: import / edit / JPEG, PNG, 16-bit TIFF export / reopen")

        // S2: Two imported files -> offline matching service -> usable output file.
        let target = try await importer.load(directory.appendingPathComponent("edited.png"))
        let result = try await MatchService(device: renderer.device).match(source: source.image, target: target.image)
        let matchedURL = directory.appendingPathComponent("matched.png")
        _ = try await exporter.writeImage(source.image, params: result.params, assets: ExportAssets(params: result.params), format: .png, to: matchedURL)
        let matched = try await importer.load(matchedURL)
        try require(matched.thumbnail.width > 0 && matched.thumbnail.height > 0, "S2: output cannot be displayed")
        print("PASS S2: two-image import / offline matching / export / reopen")

        // S3: Export a look -> import into an isolated LUT library -> apply it -> export.
        let cubeURL = directory.appendingPathComponent("look.cube")
        let cube = try await exporter.lutText(params: edits, assets: ExportAssets(params: edits), title: "Smoke look", size: 17)
        try cube.write(to: cubeURL, atomically: true, encoding: .utf8)
        let library = LutStore(dir: directory.appendingPathComponent("luts"))
        let lut = try library.importFile(cubeURL)
        var look = Params()
        look.lut = LutRef(id: lut.id, name: lut.name)
        let lookURL = directory.appendingPathComponent("look.png")
        _ = try await exporter.writeImage(source.image, params: look, assets: ExportAssets(params: look, luts: library), format: .png, to: lookURL)
        _ = try await importer.load(lookURL)
        print("PASS S3: LUT export / library import / apply / image export / reopen")
        print("UNVERIFIED S4-S8: manual app workflows; see docs/smoke.md")
    }
}
