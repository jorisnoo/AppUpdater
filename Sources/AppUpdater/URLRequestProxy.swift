import Foundation

/// A closure that transforms a URL, useful for proxying or redirecting requests.
public typealias URLTransform = @Sendable (URL) throws -> URL

extension URLRequest {
    func applying(_ transform: URLTransform?) -> URLRequest {
        guard let transform = transform, let url = self.url else { return self }

        do {
            var request = self
            request.url = try transform(url)
            return request
        } catch {
            return self
        }
    }
}
