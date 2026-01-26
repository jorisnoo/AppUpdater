import Foundation

public protocol ReleaseProvider {
    func fetchReleases(owner: String, repo: String) async throws -> [Release]
    func download(asset: Release.Asset, to saveLocation: URL) async throws -> AsyncThrowingStream<DownloadingState, Error>
}

public struct GithubReleaseProvider: ReleaseProvider, Sendable {
    public init() {}

    public func fetchReleases(owner: String, repo: String) async throws -> [Release] {
        let slug = "\(owner)/\(repo)"
        let urlString = "https://api.github.com/repos/\(slug)/releases"
        guard let url = URL(string: urlString) else {
            throw AppUpdater.Error.invalidURL(urlString)
        }
        guard let task = try await URLSession.shared.dataTask(with: url)?.validate() else {
            throw AUError.invalidCallingConvention
        }
        return try JSONDecoder().decode([Release].self, from: task.data)
    }

    public func download(asset: Release.Asset, to saveLocation: URL) async throws -> AsyncThrowingStream<DownloadingState, Error> {
        return try await URLSession.shared.downloadTask(with: asset.downloadUrl, to: saveLocation)
    }
}
