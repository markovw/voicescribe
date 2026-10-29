import Foundation

/// Pre-recorded Deepgram API. Only the extracted audio file is uploaded.
struct DeepgramClient: CloudRecognizing {
    static let endpoint = URL(string: "https://api.deepgram.com/v1/listen")!
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.ephemeral
        // The server replies only after the whole file is recognized.
        configuration.timeoutIntervalForRequest = 60 * 30
        configuration.timeoutIntervalForResource = 60 * 60 * 3
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    static func makeRequest(apiKey: String, options: DeepgramOptions) -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = options.queryItems
        // `+` is literal in URLComponents but a space for many servers.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func recognize(audio: URL, apiKey: String, options: DeepgramOptions) async throws -> Data {
        let request = Self.makeRequest(apiKey: apiKey, options: options)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: audio)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw NSError(domain: "VoiceScribe", code: 22, userInfo: [NSLocalizedDescriptionKey:
                "Could not reach Deepgram. Check the internet connection. \(error.localizedDescription)"])
        }
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "VoiceScribe", code: 23, userInfo: [NSLocalizedDescriptionKey: "Deepgram returned no HTTP response."])
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "VoiceScribe", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey:
                DeepgramResponse.errorMessage(status: http.statusCode, body: data)])
        }
        return data
    }
}
