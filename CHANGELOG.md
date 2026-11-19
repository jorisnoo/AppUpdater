# Changelog

## [4.1.0] - 2026-11-19

### Added
- Prerelease tags now support numeric marketing versions. An optional `AppUpdaterReleaseVersion` Info.plist key distinguishes betas and final releases that share a marketing version.

### Fixed
- Reuse a saved download after relaunch. Restart Now and install-on-quit install the saved copy without waiting for an active network check.
- Accept supported archive filenames regardless of the server's MIME type. Detect a translocated or read-only install before downloading and tell the user where to move the app.
- Record background failures at error level. If both relaunch and rollback fail, report both errors and the backup location.

## [4.0.0] - 2026-09-09

### Added
- Shared `AppUpdateController` and `AppUpdateMenu` for launch/background checks, manual feedback, persisted updates, and installation on quit.
- Regression coverage for tampering, concurrent checks, unsafe archives, persistence failures, and installation rollback.

### Fixed
- Verify the full signature against the installed app's designated requirement, including sealed resources, nested code, and every architecture. Validate bundle identity, version, and macOS compatibility.
- Stage installation on the destination volume, retain pending files through installation, and restore the previous app if relaunch fails.
- Drain subprocess output concurrently; enforce process timeouts and reject unsafe extraction paths.
- Coalesce overlapping checks, retain ready updates after failures, and clear busy state reliably.
- Persist updates atomically and preserve the previous update when copying fails.
- Reject failed HTTP download responses and cancel downloads when their streams are cancelled.

### Breaking
- `AppUpdater` and its callbacks are main-actor isolated; `ReleaseProvider` now requires `Sendable`.
- `Process.launching()` returns captured `Data` instead of undrained pipes.
- `Bundle.codeSigningIdentity()` returns the signing team for diagnostics; installation uses Security.framework requirements.
- `replaceBundle` returns the installed URL and retains the source bundle.

## [3.1.0] - 2026-07-11

### Breaking
- Mocks moved out of `AppUpdater` into a separate `AppUpdaterMocks` library product. Add it as a dependency of your test target and `import AppUpdaterMocks` to keep using `MockReleaseProvider`. Apps that only depend on `AppUpdater` no longer ship the mock or its JSON fixture.
- `CRTHTTPError` renamed to `HTTPError`.
- `AppUpdater.Error.noValidUpdate` removed — being up to date is no longer an error (see below).
- `AppUpdater.Error.extractionTimeout` removed; it was never thrown.
- `CancellableError` and the `Error.isCancelled` extension removed.
- `replaceBundle(_:)` is now `async throws`; call it as `try await updater.replaceBundle(bundle)`.

### Changed
- A check that finds no newer release is now a success: the state stays `.none` and the `success` callback fires instead of `fail`. A successful check also clears `lastError`.
- `replaceBundle(_:)` re-validates the downloaded bundle's code-signing identity immediately before installing, closing the window between download-time validation and a deferred install.
- Concurrent `check()` calls are deduped — while a check is in flight, further calls return immediately.
- `GithubReleaseProvider.init(session:)` accepts a caller-supplied `URLSession` and uses it for both release fetches and asset downloads.

### Fixed
- Release tags are parsed with tolerant semantic versioning, so `v1.2.3` decodes correctly instead of failing.
- Tarball assets are matched properly: `.tar`, `.tar.gz`, `.tar.xz`, `.tar.bz2` and `.tgz` are all recognised.
- Asset MIME coverage extended with `application/gzip` and `application/x-tar`.
- Download progress now reports continuously via KVO on the task's progress instead of emitting a single `0.0` before the download starts.
- The extraction timeout task is cancelled on every exit path from `unzip()`. Previously, a failure to launch the extraction process left a timer alive that later called `terminate()` on an unlaunched `Process`, crashing the host app.
- The path-traversal check on extracted archive contents compares full path components, so a sibling directory like `/tmp/foo-evil` is no longer treated as being inside `/tmp/foo`.

## [3.0.0] - 2025-02-11

### Features
- Add deferred update support (install on quit)
- Add convenience helper for common update flows

### Changed
- Remove UI components and changelog localization — bring your own UI
- Remove settings/preferences UI
- Remove example project
- Simplify core update flow and codebase

### Fixed
- Improve installation reliability with launch confirmation

### Build
- Update LICENSE copyright and SPM version for 3.0.0
- Remove unused config files
