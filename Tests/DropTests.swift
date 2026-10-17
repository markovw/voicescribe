import AppKit
import UniformTypeIdentifiers

@main struct DropTests {
    static func main() async throws {
        let expected = URL(fileURLWithPath: "/tmp/пример видео с пробелами.mp4")
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { done in
            done(expected.dataRepresentation, nil)
            return nil
        }
        let loaded: URL = try await withCheckedThrowingContinuation { continuation in
            FileDrop.read(provider) { result in continuation.resume(with: result) }
        }
        assert(loaded == expected)
        print("PASS: native file-url drop decoding with spaces and Cyrillic filename")
    }
}
