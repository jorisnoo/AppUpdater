import Foundation
import AppUpdater
import Combine

@main
struct Runner {
    static func main() async {
        print("[MockRunner] Starting mock update check...")
        let updater = AppUpdater(owner: "mock", repo: "mock", releasePrefix: "AppUpdaterExample", interval: 24*60*60, provider: MockReleaseProvider())
        updater.skipCodeSignValidation = true

        var cancellables = Set<AnyCancellable>()
        updater.$state
            .sink { state in
                switch state {
                case .none:
                    print("[MockRunner] State: none")
                case .newVersionDetected(let rel, _):
                    print("[MockRunner] Detected: v\(rel.tagName)")
                    print("[MockRunner] Assets: \(rel.assets.map { $0.name })")
                    print("[MockRunner] Body:\n\(rel.body)\n---")
                case .downloading(let rel, _, let fraction):
                    print("[MockRunner] Downloading v\(rel.tagName): \(Int(fraction*100))%")
                case .downloaded(let rel, _, _):
                    print("[MockRunner] Downloaded v\(rel.tagName)")
                }
            }
            .store(in: &cancellables)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            updater.check {
                print("[MockRunner] success callback")
                cont.resume()
            } fail: { err in
                print("[MockRunner] fail callback: \(err)")
                cont.resume()
            }
        }
        print("[MockRunner] Done.")
    }
}
