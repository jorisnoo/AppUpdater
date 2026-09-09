# AppUpdater

A macOS updater for non-sandboxed apps distributed through GitHub releases. Use the shared `AppUpdateController` for consistent behavior across apps, or use the `AppUpdater` core with your own UI.

This is a fork of [s1ntoneli/AppUpdater](https://github.com/s1ntoneli/AppUpdater), originally based on [mxcl/AppUpdater](https://github.com/mxcl/AppUpdater).

## Standard app integration

All four local consumers—Batzen, Harvie, RealExporter, and GDSPlayer—use this integration:

- Release builds check on launch and periodically, approximately every 24 hours. macOS may defer background checks.
- Automatic checks download and validate silently, then save the update for installation on quit.
- **Check for Updates…** shows an update dialog, an up-to-date message, or an error.
- The update dialog offers **Restart Now** and **Install on Quit**. A saved update also appears as **Restart and Update** in the menu.
- Pending updates survive restarts and failed checks. Failed installs retain the update for retry.
- Debug builds do not check automatically. Manual checks remain available; production signature requirements still apply.
- App Store builds exclude the integration with `#if !APP_STORE`.

```swift
import AppKit
#if !APP_STORE
import AppUpdater
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if !APP_STORE
    let updates = AppUpdateController(owner: "yourname", repo: "YourApp")

    func applicationDidFinishLaunching(_ notification: Notification) {
        updates.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        updates.applicationShouldTerminate(sender)
    }
    #endif
}
```

For a SwiftUI app, add the shared menu to the app's existing commands:

```swift
#if !APP_STORE
CommandGroup(after: .appInfo) {
    AppUpdateMenu(controller: appDelegate.updates)
}
#endif
```

For an AppKit menu-bar app, add `updates.menuItems()` to the menu when building it. The items target the controller and validate their enabled state automatically.

Set `releasePrefix` only when the archive name differs from the repository name. GDSPlayer uses:

```swift
AppUpdateController(owner: "jorisnoo", repo: "GDSPlayer", releasePrefix: "GDS.FM")
```

The controller owns persistence under `Application Support/<bundle identifier>/PendingUpdates` and the `deferredUpdate` UserDefaults key. Existing GDSPlayer deferred updates are restored automatically. Apps should not delete these files or duplicate the controller's callbacks.

## Release requirements

- macOS 12 or later; Swift 6 or later to build the package.
- Non-sandboxed app in a writable installation directory.
- Semantic release tags, such as `1.2.3` or `v1.2.3`.
- Binary assets named `YourApp-1.2.3.zip`, `.tar`, `.tar.gz`, `.tar.xz`, `.tar.bz2`, or `.tgz`. Use the normalized version without `v` in the asset filename.
- The archive contains one top-level `.app` bundle.
- The downloaded app has the expected bundle identifier and satisfies the installed app's designated code-signing requirement. Sign releases consistently with Developer ID.
- The bundle's `CFBundleShortVersionString` matches the release tag and is newer than the running app. `LSMinimumSystemVersion` must be compatible with the current macOS version.

## Installation guarantees

The package verifies sealed resources, nested code, and all architectures using Security.framework. It verifies the downloaded bundle again after copying it into a staging directory on the installation volume. An invalid signature, different app identity, or incompatible version stops installation before replacement.

Replacement retains the source update and temporarily keeps a backup of the installed app. Restarting waits for launch confirmation; if launch reports failure, the old bundle is restored. Only a confirmed launch triggers success callbacks and termination. This confirms launch, not the subsequent health of the application.

Install on quit uses the same validation and replacement, without launching another instance. If installation fails, the controller logs the failure, retains the pending update, and lets the user quit normally.

Archive extraction uses macOS `bsdtar` with its default path protections, rejects traversal paths before extraction, and validates extracted symlinks. Child-process output is drained concurrently and extraction has a timeout.

## Core API

`AppUpdater` and its callbacks are main-actor isolated. `ReleaseProvider` implementations must be `Sendable`.

```swift
let updater = AppUpdater(owner: "yourname", repo: "YourApp", automaticallyChecks: false)
try await updater.checkThrowing()

switch updater.state {
case .downloaded(_, _, let bundle):
    try await updater.installThrowing(bundle)
case .none:
    // Already up to date or no usable release.
    break
case .newVersionDetected, .downloading:
    break
}
```

Concurrent checks await the same operation and receive its result. A failed check restores the previous state, records `lastError`, and releases the busy state for retry. `isChecking` and `isInstalling` are observable. Already-downloaded releases are reused while their files exist.

For custom install-on-quit flows, `try await updater.replaceBundle(bundle)` replaces without relaunching and returns the installed app's URL. The source remains available. The caller owns its cleanup and termination reply.

The callback-based `check` and `install` methods remain available. `onDownloadSuccess`/`onDownloadFail` are background-scheduler callbacks; explicit `check` calls use their supplied callbacks. Prefer the shared controller unless the app needs a different user experience.

## Swift Package Manager

Add the GitHub package and select its `AppUpdater` product:

```swift
.package(url: "https://github.com/jorisnoo/AppUpdater.git", from: "4.0.0")
```

In Xcode, use the same repository URL with **Up to Next Major Version**, starting at **4.0.0**. Batzen, Harvie, RealExporter, and GDSPlayer all use this remote dependency. A sibling package checkout is not required for local or CI builds.

For package development, temporarily add this repository to an Xcode workspace as a local package override. Remove the override before verifying the released dependency.

### Migrating from 3.x

Use `AppUpdateController` and forward the app's launch and termination callbacks as shown above. Replace custom update menus with `AppUpdateMenu` or `menuItems()`. Remove app-owned deferred-update persistence and download/install callbacks; the controller handles them, including existing GDSPlayer saved updates.

For custom core integrations, create and access `AppUpdater` on the main actor, make providers `Sendable`, and handle `.none` as a successful check. `replaceBundle` is async and retains the source bundle; the caller owns its cleanup. See the [changelog](CHANGELOG.md) for all breaking changes.

## Tests and mocks

```sh
swift test
swift run AppUpdaterMockRunner
```

`AppUpdaterMocks` is a separate product. Tests can inject `MockReleaseProvider` and enable `skipCodeSignValidation` for placeholder bundles; do not enable it in shipping apps. The mock runner exercises checking, downloading, extraction, and state changes without installing anything.

The regression suite covers concurrent checks, process output and timeouts, unsafe archives, signature tampering, persistence, deferred updates, install-on-quit ordering, and relaunch rollback.

For diagnostics, filter Console.app by the `AppUpdater` subsystem.
