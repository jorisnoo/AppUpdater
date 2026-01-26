# AppUpdater

> **Fork Notice:** This is a simplified fork of [s1ntoneli/AppUpdater](https://github.com/s1ntoneli/AppUpdater),
> which itself is a rewrite of [mxcl/AppUpdater](https://github.com/mxcl/AppUpdater).
>
> This fork removes UI components and changelog localization to provide a lean,
> headless update library. Bring your own UI.

A simple app-updater for macOS, checks your GitHub releases for a binary asset and silently updates your app.

## Changes from Upstream

- Removed `AppUpdaterSettings` SwiftUI view
- Removed `MarkdownUI` dependency
- Removed changelog localization (`localizedChangelog()`, `preferredChangelogLanguages`)
- Removed deprecated `downloadedAppBundle` property
- Replaced `debugInfo` array with OSLog (filter "AppUpdater" in Console.app)
- Added 34 unit tests
- Simplified `ReleaseProvider` protocol (removed `fetchAssetData()`)

## Caveats

* Assets must be named: `\(name)-\(semanticVersion).ext`. See [Semantic Version](https://github.com/mxcl/Version)
* Only non-sandboxed apps are supported

## Features

* Full semantic versioning support: we understand alpha/beta etc.
* We check that the code-sign identity of the download matches the running app before updating. So if you don't code-sign I'm not sure what would happen.
* We support zip files or tarballs.
* We support a proxy parameter for those unable to normally access GitHub

## Usage

### Swift Package Manager
```swift
package.dependencies.append(.package(url: "https://github.com/jorisnoo/AppUpdater.git", from: "1.0.0"))
```

### Initialize
```swift
var appUpdater = AppUpdater(owner: "yourname", repo: "YourApp")
```

### Check for Updates and Auto Download
```swift
appUpdater.check()
```

### Manual Install
```swift
appUpdater.install()
```

### SwiftUI
**AppUpdater is an ObservableObject**, can be used directly in SwiftUI to build your own update UI.

### Custom Proxy
For those unable to normally access GitHub, you can implement a custom proxy:

**Proxy Implementation Reference Gist:** [github-api-proxy.js](https://gist.github.com/jorisnoo/69ef19899710d25c77a93e9b6e433c5b)

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
