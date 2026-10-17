import Darwin
import Foundation
import MacCoffeeCore

enum LidAwakeBootstrapDiagnostic {
    private struct IdentityReport: Encodable {
        let valid: Bool
        let executablePath: String
        let identifier: String?
        let codeHash: String?
        let requirement: String?
        let error: String?
    }

    private struct Report: Encodable {
        let arguments: [String]
        let currentDirectory: String
        let bundleMainPath: String
        let processExecutablePath: String?
        let pathResolutionError: String?
        let derivedApplicationBundlePath: String?
        let expectedHelperExecutablePath: String?
        let helperPathMatchesBundleLayout: Bool?
        let helperIdentity: IdentityReport?
        let applicationExecutablePath: String?
        let applicationIdentityMatchesExpectedIdentifier: Bool?
        let applicationIdentity: IdentityReport?
    }

    static func current() -> (json: String, isReady: Bool) {
        let processURL: URL?
        let pathError: String?
        do {
            processURL = try LidAwakeProcessPath.executableURL(for: getpid())
            pathError = nil
        } catch {
            processURL = nil
            pathError = error.localizedDescription
        }

        let applicationBundleURL = processURL.map {
            LidAwakeServiceConfiguration.applicationBundleURL(containingHelperAt: $0)
        }
        let expectedHelperURL = applicationBundleURL.map {
            LidAwakeServiceConfiguration.helperExecutableURL(in: $0)
                .standardizedFileURL.resolvingSymlinksInPath()
        }
        let helperPathMatches = zipOptional(processURL, expectedHelperURL) { $0.path == $1.path }
        let applicationExecutableURL = applicationBundleURL.map {
            LidAwakeServiceConfiguration.applicationExecutableURL(in: $0)
                .standardizedFileURL.resolvingSymlinksInPath()
        }
        let helperIdentity = processURL.map(identityReport)
        let applicationIdentity = applicationExecutableURL.map(identityReport)
        let applicationIdentifierMatches = applicationIdentity.map {
            $0.valid && $0.identifier == LidAwakeServiceConfiguration.applicationIdentifier
        }

        let report = Report(
            arguments: CommandLine.arguments,
            currentDirectory: FileManager.default.currentDirectoryPath,
            bundleMainPath: Bundle.main.bundleURL.path,
            processExecutablePath: processURL?.path,
            pathResolutionError: pathError,
            derivedApplicationBundlePath: applicationBundleURL?.path,
            expectedHelperExecutablePath: expectedHelperURL?.path,
            helperPathMatchesBundleLayout: helperPathMatches,
            helperIdentity: helperIdentity,
            applicationExecutablePath: applicationExecutableURL?.path,
            applicationIdentityMatchesExpectedIdentifier: applicationIdentifierMatches,
            applicationIdentity: applicationIdentity
        )
        let isReady = helperPathMatches == true
            && helperIdentity?.valid == true
            && applicationIdentifierMatches == true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(report)
            return (String(decoding: data, as: UTF8.self), isReady)
        } catch {
            return ("{\"diagnosticEncodingError\": \(error.localizedDescription.debugDescription)}", false)
        }
    }

    private static func identityReport(at executableURL: URL) -> IdentityReport {
        do {
            let identity = try LidAwakeCodeIdentityReader.read(executableURL: executableURL)
            return IdentityReport(
                valid: true,
                executablePath: identity.executablePath,
                identifier: identity.identifier,
                codeHash: identity.codeHash,
                requirement: identity.requirement,
                error: nil
            )
        } catch {
            return IdentityReport(
                valid: false,
                executablePath: executableURL.path,
                identifier: nil,
                codeHash: nil,
                requirement: nil,
                error: error.localizedDescription
            )
        }
    }

    private static func zipOptional<T, U, V>(
        _ first: T?,
        _ second: U?,
        transform: (T, U) -> V
    ) -> V? {
        guard let first, let second else { return nil }
        return transform(first, second)
    }
}
