import Foundation
import Security
@preconcurrency import Version

public extension Bundle {
    func isCodeSigned() async -> Bool {
        let url = bundleURL
        return await Task.detached {
            guard let code = try? Self.staticCode(at: url) else { return false }
            return SecStaticCodeCheckValidity(code, Self.validationFlags, nil) == errSecSuccess
        }.value
    }

    /// The signing team, for diagnostics. Installation uses the designated requirement.
    func codeSigningIdentity() async throws -> String? {
        let code = try Self.staticCode(at: bundleURL)
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else {
            throw AppUpdater.Error.codeSigningIdentity
        }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

extension Bundle {
    // Read staged metadata from disk: Foundation caches Bundle instances by URL.
    var updateVersion: Version {
        guard let data = try? Data(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let raw = info["CFBundleShortVersionString"] as? String,
              let version = Version(tolerant: raw) else { return .null }
        return version
    }

    private static var validationFlags: SecCSFlags {
        SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
    }

    private static func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw AppUpdater.Error.codeSigningIdentity
        }
        return code
    }

    static func validateUpdate(at candidate: URL, against installed: URL) throws {
        guard let identifier = Bundle(url: installed)?.bundleIdentifier,
              Bundle(url: candidate)?.bundleIdentifier == identifier else {
            throw AppUpdater.Error.codeSigningIdentity
        }
        let current = try staticCode(at: installed)
        let downloaded = try staticCode(at: candidate)
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(current, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(downloaded, validationFlags, requirement) == errSecSuccess else {
            throw AppUpdater.Error.codeSigningIdentity
        }
    }
}
