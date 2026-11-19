import XCTest
import AppKit
import Version
@testable import AppUpdater
import AppUpdaterMocks

@MainActor
final class UpdateReliabilityTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func bundle(in directory: URL, name: String = "Review", version: String = "1.0.0", identifier: String = "test.appupdater.review", releaseVersion: String? = nil) throws -> Bundle {
        let url = directory.appendingPathComponent(name + ".app")
        let macOS = url.appendingPathComponent("Contents/MacOS")
        let resources = url.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: macOS.appendingPathComponent("Review"))
        try Data(version.utf8).write(to: resources.appendingPathComponent("version.txt"))
        var info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Review", "CFBundlePackageType": "APPL",
                    "CFBundleShortVersionString": version, "CFBundleVersion": version, "CFBundleName": "Review"]
        info["AppUpdaterReleaseVersion"] = releaseVersion
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(Bundle(url: url))
    }

    private func updater(installed: Bundle) -> AppUpdater {
        let updater = AppUpdater(owner: "test", repo: "Review", automaticallyChecks: false)
        updater.installedBundle = installed
        return updater
    }

    func testVerboseProcessDrainsBothPipes() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "i=0; while [ $i -lt 10000 ]; do echo stdout-output; echo stderr-output >&2; i=$((i+1)); done"]
        let (out, err) = try await process.launching(timeout: 10)
        XCTAssertEqual(out.count, 140_000)
        XCTAssertEqual(err.count, 140_000)
    }

    func testMockUpdateDownloadsAndExtractsEndToEnd() async throws {
        let root = try temporaryDirectory()
        let installed = try bundle(in: root)
        let updater = AppUpdater(owner: "test", repo: "test", releasePrefix: "AppUpdaterExample",
                                 provider: MockReleaseProvider(simulatedSteps: 1, simulatedDelay: 0), automaticallyChecks: false)
        updater.installedBundle = installed
        updater.skipCodeSignValidation = true
        try await updater.checkThrowing()
        guard case .downloaded(_, _, let downloaded) = updater.state else { return XCTFail("Expected downloaded update") }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: try XCTUnwrap(downloaded.executableURL).path))
    }

    func testProcessLaunchFailureAndTimeoutFinish() async throws {
        let missing = Process()
        missing.executableURL = URL(fileURLWithPath: "/nonexistent/appupdater-review")
        do { _ = try await missing.launching(); XCTFail("Expected launch failure") } catch { }
        let slow = Process()
        slow.executableURL = URL(fileURLWithPath: "/bin/sleep")
        slow.arguments = ["10"]
        do { _ = try await slow.launching(timeout: 0.05); XCTFail("Expected timeout") } catch { }
        XCTAssertFalse(slow.isRunning)
    }

    func testTamperedSignedBundleIsRejected() async throws {
        let root = try temporaryDirectory()
        let current = try bundle(in: root)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", current.bundlePath]
        _ = try await sign.launching()
        let candidate = root.appendingPathComponent("Candidate.app")
        try FileManager.default.copyItem(at: current.bundleURL, to: candidate)
        XCTAssertNoThrow(try Bundle.validateUpdate(at: candidate, against: current.bundleURL))
        try Data("tampered".utf8).write(to: candidate.appendingPathComponent("Contents/Resources/version.txt"))
        XCTAssertThrowsError(try Bundle.validateUpdate(at: candidate, against: current.bundleURL))
    }

    func testDifferentApplicationIdentityIsRejected() throws {
        let root = try temporaryDirectory()
        let current = try bundle(in: root)
        let other = try bundle(in: root, name: "Other", identifier: "test.other")
        XCTAssertThrowsError(try Bundle.validateUpdate(at: other.bundleURL, against: current.bundleURL))
    }

    func testPersistenceFailureKeepsPreviousUpdate() throws {
        let root = try temporaryDirectory()
        let source = try bundle(in: root)
        let directory = root.appendingPathComponent("Pending")
        let saved = try DeferredUpdate.persistBundle(source, to: directory)
        try FileManager.default.removeItem(at: source.bundleURL)
        XCTAssertThrowsError(try DeferredUpdate.persistBundle(source, to: directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.appendingPathComponent("Contents/MacOS/Review").path))
    }

    func testPersistingAlreadySavedBundleDoesNotDeleteIt() throws {
        let root = try temporaryDirectory()
        let source = try bundle(in: root)
        let directory = root.appendingPathComponent("Pending")
        let saved = try DeferredUpdate.persistBundle(source, to: directory)
        let stored = try XCTUnwrap(Bundle(url: saved))
        XCTAssertEqual(try DeferredUpdate.persistBundle(stored, to: directory), saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.executableURL!.path))
    }

    func testFailedRelaunchRollsBackAndKeepsPendingBundle() async throws {
        let root = try temporaryDirectory()
        let installed = try bundle(in: root)
        let update = try bundle(in: root, name: "Candidate", version: "2.0.0")
        let updater = updater(installed: installed)
        updater.skipCodeSignValidation = true
        updater.launchApplication = { _ in throw AppUpdater.Error.relaunchFailed }
        updater.terminateApplication = { XCTFail("Must not quit after a failed relaunch") }
        do { try await updater.installThrowing(update); XCTFail("Expected relaunch failure") } catch { }
        XCTAssertEqual(installed.updateVersion.description, "1.0.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: update.executableURL!.path))
        XCTAssertFalse(updater.isInstalling)
    }

    func testRollbackFailureReportsBothErrorsAndRetainsBackup() async throws {
        let root = try temporaryDirectory()
        let installed = try bundle(in: root)
        let update = try bundle(in: root, name: "Candidate", version: "2.0.0")
        let updater = updater(installed: installed)
        updater.skipCodeSignValidation = true
        updater.launchApplication = { _ in throw AppUpdater.Error.relaunchFailed }
        updater.restoreBackup = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        updater.terminateApplication = { XCTFail("Must not quit") }
        do {
            try await updater.installThrowing(update)
            XCTFail("Expected rollback failure")
        } catch let failure as RollbackError {
            XCTAssertEqual(failure.launchError.localizedDescription, AppUpdater.Error.relaunchFailed.localizedDescription)
            XCTAssertEqual((failure.rollbackError as NSError).code, CocoaError.fileWriteNoPermission.rawValue)
            XCTAssertTrue(failure.localizedDescription.contains(failure.backup.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: failure.backup.path))
        }
        XCTAssertEqual(installed.updateVersion.description, "2.0.0")
        XCTAssertFalse(updater.isInstalling)
    }

    func testPrereleaseValidatesNumericMarketingVersionWithoutAcceptingWrongRelease() throws {
        let root = try temporaryDirectory()
        let installed = try bundle(in: root)
        let numeric = try bundle(in: root, name: "Candidate", version: "2.0.0")
        let first = try XCTUnwrap(Version("2.0.0-beta.1"))
        let next = try XCTUnwrap(Version("2.0.0-beta.2"))
        let updater = updater(installed: installed)
        XCTAssertNoThrow(try updater.validateVersion(numeric, expected: first))
        XCTAssertThrowsError(try updater.validateVersion(numeric, expected: Version(2, 1, 0)))
        let tagged = try bundle(in: root, name: "Tagged", version: "2.0.0", releaseVersion: first.description)
        XCTAssertThrowsError(try updater.validateVersion(tagged, expected: next))
        updater.installedBundle = tagged
        XCTAssertThrowsError(try updater.validateVersion(tagged, expected: first))
        XCTAssertNoThrow(try updater.validateVersion(numeric, expected: Version(2, 0, 0)))
    }

    func testTranslocatedInstallIsRejectedBeforeDownloading() async throws {
        let root = try temporaryDirectory()
        let installed = try bundle(in: root.appendingPathComponent("AppTranslocation/ABC/d"))
        let updater = AppUpdater(owner: "test", repo: "AppUpdaterExample", provider: MetadataOnlyProvider(), automaticallyChecks: false)
        updater.installedBundle = installed
        do {
            try await updater.checkThrowing()
            XCTFail("Expected location error")
        } catch is InstallLocationError { }
    }

    func testUnwritableParentIsRejectedBeforeDownloading() async throws {
        let root = try temporaryDirectory()
        let installed = try bundle(in: root)
        let updater = AppUpdater(owner: "test", repo: "AppUpdaterExample", provider: MetadataOnlyProvider(), automaticallyChecks: false)
        updater.installedBundle = installed
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: root.path), "Privileged process bypasses directory permissions")
        do {
            try await updater.checkThrowing()
            XCTFail("Expected location error")
        } catch is InstallLocationError { }
    }

    func testSuccessfulInstallKeepsSourceUntilSuccessCallback() async throws {
        let root = try temporaryDirectory()
        let installed = try bundle(in: root)
        let update = try bundle(in: root, name: "Candidate", version: "2.0.0")
        let updater = updater(installed: installed)
        updater.skipCodeSignValidation = true
        var events: [String] = []
        updater.launchApplication = { url in
            XCTAssertEqual(url, installed.bundleURL)
            XCTAssertEqual(installed.updateVersion.description, "2.0.0")
            events.append("launch")
        }
        updater.onInstallSuccess = {
            XCTAssertTrue(FileManager.default.fileExists(atPath: update.executableURL!.path))
            events.append("success")
        }
        updater.terminateApplication = { events.append("terminate") }
        let provider = GatedProvider()
        updater.provider = provider
        let check = Task { try await updater.checkThrowing() }
        while await provider.calls == 0 { await Task.yield() }
        try await updater.installThrowing(update)
        await provider.finish()
        do { try await check.value; XCTFail("Install should supersede check") } catch is CancellationError { }
        XCTAssertEqual(events, ["launch", "success", "terminate"])
        XCTAssertFalse(updater.isInstalling)
    }

    func testInstallRevalidatesSignatureBeforeReplacing() async throws {
        let root = try temporaryDirectory()
        let installed = try bundle(in: root)
        let update = try bundle(in: root, name: "Candidate", version: "2.0.0")
        let updater = updater(installed: installed)
        do { try await updater.replaceBundle(update); XCTFail("Unsigned update must fail") } catch { }
        XCTAssertEqual(installed.updateVersion.description, "1.0.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: update.executableURL!.path))
    }

    func testConcurrentChecksWaitForSameResultAndCanRetry() async throws {
        let provider = GatedProvider()
        let updater = AppUpdater(owner: "test", repo: "Review", provider: provider, automaticallyChecks: false)
        let first = Task { try await updater.checkThrowing() }
        while await provider.calls == 0 { await Task.yield() }
        var secondStarted = false
        var secondFinished = false
        let second = Task {
            secondStarted = true
            try await updater.checkThrowing()
            secondFinished = true
        }
        while !secondStarted { await Task.yield() }
        XCTAssertFalse(secondFinished)
        await provider.finish()
        try await first.value
        try await second.value
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(updater.isChecking)
        let retry = Task { try await updater.checkThrowing() }
        while await provider.calls == 1 { await Task.yield() }
        await provider.finish()
        try await retry.value
        XCTAssertFalse(updater.isChecking)
    }

    func testControllerPreservesPendingUpdateWhenCheckFails() async throws {
        let root = try temporaryDirectory()
        let installed = try bundle(in: root)
        let downloaded = try bundle(in: root, name: "Candidate", version: "2.0.0")
        let updater = updater(installed: installed)
        let releases = try await MockReleaseProvider().fetchReleases(owner: "test", repo: "test")
        let release = try XCTUnwrap(releases.first)
        let asset = try XCTUnwrap(release.assets.first)
        let suite = "AppUpdaterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = root.appendingPathComponent("Pending")
        let controller = AppUpdateController(updater: updater, defaults: defaults, directory: directory, automaticChecks: false)
        updater.state = .downloaded(release, asset, downloaded)
        try controller.saveDownloadedUpdate()
        updater.provider = FailingProvider()
        do { try await updater.checkThrowing(); XCTFail("Expected network failure") } catch { }
        XCTAssertNotNil(controller.pendingUpdate?.loadBundle())
        XCTAssertNotNil(updater.lastError)
        if case .downloaded = updater.state { } else { XCTFail("Ready state must survive failure") }
        let relaunched = AppUpdater(owner: "test", repo: "AppUpdaterExample", provider: MetadataOnlyProvider(), automaticallyChecks: false)
        relaunched.installedBundle = installed
        let restored = AppUpdateController(updater: relaunched, defaults: defaults, directory: directory, automaticChecks: false)
        let saved = try XCTUnwrap(restored.pendingUpdate?.bundlePath)
        try await relaunched.checkThrowing()
        guard case .downloaded(_, _, let reused) = relaunched.state else { return XCTFail("Expected restored update") }
        XCTAssertEqual(reused.bundlePath, saved)
    }

    func testInstallOnQuitReplacesBeforeCleaningUpAndRepliesOnce() async throws {
        let root = try temporaryDirectory()
        let installed = try bundle(in: root)
        let downloaded = try bundle(in: root, name: "Candidate", version: "2.0.0")
        let updater = updater(installed: installed)
        updater.skipCodeSignValidation = true
        let releases = try await MockReleaseProvider().fetchReleases(owner: "test", repo: "test")
        let release = try XCTUnwrap(releases.first)
        let asset = try XCTUnwrap(release.assets.first)
        let suite = "AppUpdaterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = root.appendingPathComponent("Pending")
        let controller = AppUpdateController(updater: updater, defaults: defaults, directory: directory, automaticChecks: false)
        updater.state = .downloaded(release, asset, downloaded)
        try controller.saveDownloadedUpdate()
        let application = ReplyApplication()
        let replied = expectation(description: "Termination reply")
        application.onReply = { shouldTerminate in
            XCTAssertTrue(shouldTerminate)
            XCTAssertEqual(installed.updateVersion.description, "2.0.0")
            XCTAssertNil(controller.pendingUpdate)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            replied.fulfill()
        }
        let provider = GatedProvider()
        updater.provider = provider
        let check = Task { try await updater.checkThrowing() }
        while await provider.calls == 0 { await Task.yield() }
        XCTAssertEqual(controller.applicationShouldTerminate(application), .terminateLater)
        XCTAssertEqual(controller.applicationShouldTerminate(application), .terminateCancel)
        await fulfillment(of: [replied], timeout: 5)
        // Quit has already been approved even though this provider has not returned.
        XCTAssertEqual(controller.applicationShouldTerminate(application), .terminateNow)
        do { try await updater.checkThrowing(); XCTFail("No new check during termination") } catch is CancellationError { }
        await provider.finish()
        do { try await check.value; XCTFail("Old check should be cancelled") } catch is CancellationError { }
        XCTAssertNil(updater.lastError)
    }

    func testOutdatedDeferredUpdateIsDiscardedOnLaunch() async throws {
        let root = try temporaryDirectory()
        let installed = try bundle(in: root, version: "3.0.0")
        let downloaded = try bundle(in: root, name: "Candidate", version: "2.0.0")
        let directory = root.appendingPathComponent("Pending")
        let saved = try DeferredUpdate.persistBundle(downloaded, to: directory)
        let pending = DeferredUpdate(bundlePath: saved.path, releaseVersion: "2.0.0", releaseName: "Old", assetName: "Review-2.0.0.zip")
        let suite = "AppUpdaterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(pending), forKey: "deferredUpdate")
        let controller = AppUpdateController(updater: updater(installed: installed), defaults: defaults, directory: directory, automaticChecks: false)
        XCTAssertNil(controller.pendingUpdate)
        XCTAssertNil(defaults.data(forKey: "deferredUpdate"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
    }

    func testArchiveCannotWriteThroughEscapingSymlink() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Source")
        let extraction = root.appendingPathComponent("Extraction")
        let outside = root.appendingPathComponent("Outside")
        for dir in [source, extraction, outside] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("escape"), withDestinationURL: outside)
        let archive = extraction.appendingPathComponent("download")
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        create.currentDirectoryURL = source
        create.arguments = ["-cf", archive.path, "escape"]
        _ = try await create.launching()
        try FileManager.default.removeItem(at: source.appendingPathComponent("escape"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("escape"), withIntermediateDirectories: true)
        try Data("must stay inside".utf8).write(to: source.appendingPathComponent("escape/payload"))
        let append = Process()
        append.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        append.currentDirectoryURL = source
        append.arguments = ["-rf", archive.path, "escape/payload"]
        _ = try await append.launching()
        do { _ = try await unzip(archive); XCTFail("Unsafe archive must fail") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("payload").path))
    }
}

private actor GatedProvider: ReleaseProvider {
    var calls = 0
    private var continuation: CheckedContinuation<[Release], Never>?
    func fetchReleases(owner: String, repo: String) async throws -> [Release] {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: []); continuation = nil }
    func download(asset: Release.Asset, to saveLocation: URL) async throws -> AsyncThrowingStream<DownloadingState, Error> {
        throw AppUpdater.Error.downloadFailed
    }
}

private struct MetadataOnlyProvider: ReleaseProvider {
    func fetchReleases(owner: String, repo: String) async throws -> [Release] {
        try await MockReleaseProvider().fetchReleases(owner: owner, repo: repo)
    }

    func download(asset: Release.Asset, to saveLocation: URL) async throws -> AsyncThrowingStream<DownloadingState, Error> {
        XCTFail("A download was not expected")
        throw AppUpdater.Error.downloadFailed
    }
}

private struct FailingProvider: ReleaseProvider {
    func fetchReleases(owner: String, repo: String) async throws -> [Release] { throw URLError(.notConnectedToInternet) }
    func download(asset: Release.Asset, to saveLocation: URL) async throws -> AsyncThrowingStream<DownloadingState, Error> { throw URLError(.notConnectedToInternet) }
}

@MainActor
private final class ReplyApplication: NSApplication {
    var onReply: ((Bool) -> Void)?
    override func reply(toApplicationShouldTerminate shouldTerminate: Bool) { onReply?(shouldTerminate) }
}
