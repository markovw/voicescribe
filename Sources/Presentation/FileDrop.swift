import Foundation
import AppKit

enum FileDrop {
    static func read(_ provider: NSItemProvider, completion: @escaping (Result<URL, Error>) -> Void) {
        provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, error in
            if let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                completion(.success(url)); return
            }
            completion(.failure(error ?? NSError(domain: "VoiceScribe", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Could not read the dropped file. Use Open file to select it."])))
        }
    }
}

