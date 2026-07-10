# Changelog

## [4.0.0] - 2026-07-10

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
