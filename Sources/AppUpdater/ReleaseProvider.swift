import Foundation

public protocol ReleaseProvider: Sendable {
    func fetchReleases(owner: String, repo: String) async throws -> [Release]
    func download(asset: Release.Asset, to saveLocation: URL) async throws -> AsyncThrowingStream<DownloadingState, Error>
}

public struct GithubReleaseProvider: ReleaseProvider, Sendable {
    @usableFromInline
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Unlike the request (idle) timeout, this also bounds a continually trickling download.
        configuration.timeoutIntervalForResource = 15 * 60
        return URLSession(configuration: configuration)
    }()

    let session: URLSession

    public init(session: URLSession = GithubReleaseProvider.defaultSession) {
        self.session = session
    }

    public func fetchReleases(owner: String, repo: String) async throws -> [Release] {
        let slug = "\(owner)/\(repo)"
        let urlString = "https://api.github.com/repos/\(slug)/releases"
        guard let url = URL(string: urlString) else {
            throw AppUpdater.Error.invalidURL(urlString)
        }
        let (data, response) = try await session.data(from: url)
        try Task.checkCancellation()
        let result = try URLTaskResult(data: data, response: response).validate()
        return try JSONDecoder().decode([Release].self, from: result.data)
    }

    public func download(asset: Release.Asset, to saveLocation: URL) async throws -> AsyncThrowingStream<DownloadingState, Error> {
        return try await session.downloadTask(with: asset.downloadUrl, to: saveLocation)
    }
}
