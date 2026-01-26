# AppUpdater

> **Fork Notice:** This is a simplified fork of [s1ntoneli/AppUpdater](https://github.com/s1ntoneli/AppUpdater),
> which itself is a rewrite of [mxcl/AppUpdater](https://github.com/mxcl/AppUpdater).
>
> This fork removes UI components and changelog localization to provide a lean,
> headless update library. Bring your own UI.

A simple app-updater for macOS, checks your GitHub releases for a binary asset, downloads it, and provides a validated bundle ready for installation.

## Caveats

* Assets must be named: `\(name)-\(semanticVersion).ext`. See [Semantic Version](https://github.com/mxcl/Version)
* Only non-sandboxed apps are supported

## Features

* Full semantic versioning support: we understand alpha/beta etc.
* We check that the code-sign identity of the download matches the running app before updating.
* We support zip files or tarballs.

## Usage

### Swift Package Manager
```swift
package.dependencies.append(.package(url: "https://github.com/jorisnoo/AppUpdater.git", from: "1.0.0"))
```

### Initialize
```swift
let updater = AppUpdater(owner: "yourname", repo: "YourApp")
```

**Full initializer:**
```swift
let updater = AppUpdater(
    owner: "yourname",
    repo: "YourApp",
    releasePrefix: "YourApp",      // defaults to repo name
    interval: 24 * 60 * 60,        // background check interval in seconds
    provider: GithubReleaseProvider()
)
```

### Check for Updates
```swift
updater.check()
```

This checks GitHub for new releases, downloads the asset if a newer version is found, validates the code signature, and transitions to the `.downloaded` state. It does **not** install the update automatically.

### Install an Update
```swift
// Get the bundle from the downloaded state
if case .downloaded(_, _, let bundle) = updater.state {
    updater.install(bundle)
}
```

The `install(_:)` method replaces the running app with the downloaded bundle and relaunches.

## Update Flow

AppUpdater uses a state machine to track progress:

```
.none → .newVersionDetected → .downloading → .downloaded
```

| State | Description |
|-------|-------------|
| `.none` | No update available or not yet checked |
| `.newVersionDetected(release, asset)` | A newer version was found, download starting |
| `.downloading(release, asset, fraction)` | Download in progress (0.0 to 1.0) |
| `.downloaded(release, asset, bundle)` | Ready to install; bundle is validated |

### SwiftUI Example

```swift
import SwiftUI
import AppUpdater

struct UpdateView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        switch updater.state {
        case .none:
            Text("No updates available")
        case .newVersionDetected(let release, _):
            Text("Found \(release.tagName.description)")
        case .downloading(_, _, let fraction):
            ProgressView(value: fraction)
        case .downloaded(let release, _, let bundle):
            VStack {
                Text("Ready to install \(release.tagName.description)")
                Button("Install & Restart") {
                    updater.install(bundle)
                }
            }
        }
    }
}
```

**AppUpdater is an ObservableObject**, observe the `state` property to build your own update UI.

## Architecture

- **Core:** `AppUpdater` checks GitHub releases, selects a viable asset, downloads, validates code-signing, and installs.
- **Providers:** Data source abstraction.
  - `GithubReleaseProvider` (default) talks to GitHub API and assets.
  - `MockReleaseProvider` (testing) serves releases from bundled JSON and produces minimal .app archives for offline testing.

## Mock Provider & Testing

Swap providers via initializer or at runtime:

```swift
let updater = AppUpdater(owner: "...", repo: "...", provider: GithubReleaseProvider())
// or
updater.provider = MockReleaseProvider()
updater.skipCodeSignValidation = true // recommended when using mocks
```

Mock data lives in `Sources/AppUpdater/Resources/Mocks/releases.mock.json`.

### CLI Mock Runner

Run the mock provider from the command line:

```bash
swift run AppUpdaterMockRunner
```

Shows state transitions and completes without touching your installed app.

## Running Tests

```bash
swift test
```

The test suite covers version comparison, asset selection, download simulation, and provider behavior.

## Debugging

Use Console.app and filter by "AppUpdater" subsystem to see debug logs.

## Alternatives

* [Sparkle](https://github.com/sparkle-project/Sparkle)
* [Squirrel](https://github.com/Squirrel/Squirrel.Mac)

## References

* [mxcl/AppUpdater](https://github.com/mxcl/AppUpdater) - Original implementation
* [s1ntoneli/AppUpdater](https://github.com/s1ntoneli/AppUpdater) - Upstream fork with async/await rewrite
