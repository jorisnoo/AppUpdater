import Foundation

extension URLSession {
    func dataTask(with convertible: URLRequestConvertible, urlTransform: URLTransform? = nil) async throws -> URLTaskResult? {
        return try await withCheckedThrowingContinuation { continuation in
            dataTask(with: convertible.request.applying(urlTransform)) { data, response, err in
                guard let data, let response else {
                    continuation.resume(throwing: err ?? AUError.invalidCallingConvention)
                    return
                }
                continuation.resume(returning: URLTaskResult(data: data, response: response))
            }.resume()
        }
    }

    func downloadTask(with convertible: URLRequestConvertible, to saveLocation: URL, urlTransform: URLTransform? = nil) async throws -> AsyncThrowingStream<DownloadingState, Error> {
        let request = convertible.request.applying(urlTransform)

        return AsyncThrowingStream<DownloadingState, Error> { continuation in
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }

                let task = downloadTask(with: request) { tmp, rso, err in
                    if let error = err {
                        continuation.finish(throwing: error)
                    } else if rso != nil, let tmp = tmp {
                        do {
                            try FileManager.default.moveItem(at: tmp, to: saveLocation)
                            continuation.yield(.finished(saveLocation: saveLocation))
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    } else {
                        continuation.finish(throwing: AUError.invalidCallingConvention)
                    }
                }
                continuation.yield(.progress(fractionCompleted: task.progress.fractionCompleted))
                task.resume()
            }
        }
    }
}

public struct URLTaskResult: Sendable {
    let data: Data
    let response: URLResponse
}

public protocol URLRequestConvertible {
    var request: URLRequest { get }
}

extension URLRequest: URLRequestConvertible {
    public var request: URLRequest { return self }
}

extension URL: URLRequestConvertible {
    public var request: URLRequest { return URLRequest(url: self) }
}

extension URLTaskResult {
    func validate() throws -> URLTaskResult {
        guard let response = self.response as? HTTPURLResponse else { return self }

        switch response.statusCode {
        case 200..<300:
            return self
        case let code:
            throw CRTHTTPError.badStatusCode(code, self.data, response)
        }
    }
}

public enum CRTHTTPError: Error, LocalizedError, CustomStringConvertible {
    case badStatusCode(Int, Data, HTTPURLResponse)

    public var errorDescription: String? {
        switch self {
        case .badStatusCode(401, _, let response):
            return "Unauthorized (\(response.url?.absoluteString ?? "nil"))"
        case .badStatusCode(let code, _, let response):
            return "Invalid HTTP response (\(code)) for \(response.url?.absoluteString ?? "nil")."
        }
    }

    public var failureReason: String? {
        switch self {
        case .badStatusCode(_, let data, _):
            return String(data: data, encoding: .utf8)
        }
    }

    public var description: String {
        switch self {
        case .badStatusCode(let code, let data, let response):
            var dict: [String: Any] = [
                "Status Code": code,
                "Body": String(data: data, encoding: .utf8) ?? "\(data.count) bytes"
            ]
            dict["URL"] = response.url
            dict["Headers"] = response.allHeaderFields
            return "<NSHTTPResponse> \(NSDictionary(dictionary: dict))"
        }
    }
}

public enum DownloadingState: Sendable {
    case progress(fractionCompleted: Double)
    case finished(saveLocation: URL)
}
