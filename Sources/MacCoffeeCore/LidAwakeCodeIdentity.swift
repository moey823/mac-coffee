import Foundation
import Security

public struct LidAwakeCodeIdentity: Equatable, Sendable {
    public let executablePath: String
    public let designatedRequirement: String
    public let requirement: String
    public let codeHash: String
    public let identifier: String
}

public enum LidAwakeCodeIdentityError: Error, LocalizedError {
    case staticCodeCreation(OSStatus)
    case invalidSignature(OSStatus)
    case signingInformation(OSStatus)
    case missingCodeHash
    case missingIdentifier
    case designatedRequirement(OSStatus)
    case requirementString(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .staticCodeCreation(let status): "Could not inspect the signed executable (Security error \(status))."
        case .invalidSignature(let status): "The executable signature is not valid (Security error \(status))."
        case .signingInformation(let status): "Could not read executable signing information (Security error \(status))."
        case .missingCodeHash: "The executable signature has no code hash."
        case .missingIdentifier: "The executable signature has no identifier."
        case .designatedRequirement(let status): "Could not read the executable's designated requirement (Security error \(status))."
        case .requirementString(let status): "Could not convert the designated requirement (Security error \(status))."
        }
    }
}

public enum LidAwakeCodeIdentityReader {
    public static func read(executableURL: URL) throws -> LidAwakeCodeIdentity {
        let resolvedURL = executableURL.standardizedFileURL.resolvingSymlinksInPath()
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(resolvedURL as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw LidAwakeCodeIdentityError.staticCodeCreation(createStatus)
        }
        let validationStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        )
        guard validationStatus == errSecSuccess else {
            throw LidAwakeCodeIdentityError.invalidSignature(validationStatus)
        }

        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard informationStatus == errSecSuccess,
              let information = information as? [CFString: Any] else {
            throw LidAwakeCodeIdentityError.signingInformation(informationStatus)
        }
        guard let hashData = information[kSecCodeInfoUnique] as? Data else {
            throw LidAwakeCodeIdentityError.missingCodeHash
        }
        guard let identifier = information[kSecCodeInfoIdentifier] as? String else {
            throw LidAwakeCodeIdentityError.missingIdentifier
        }

        var designatedRequirement: SecRequirement?
        let designatedStatus = SecCodeCopyDesignatedRequirement(
            staticCode,
            SecCSFlags(),
            &designatedRequirement
        )
        guard designatedStatus == errSecSuccess, let designatedRequirement else {
            throw LidAwakeCodeIdentityError.designatedRequirement(designatedStatus)
        }
        var designatedString: CFString?
        let stringStatus = SecRequirementCopyString(
            designatedRequirement,
            SecCSFlags(),
            &designatedString
        )
        guard stringStatus == errSecSuccess, let designatedString else {
            throw LidAwakeCodeIdentityError.requirementString(stringStatus)
        }

        let hash = hashData.map { String(format: "%02X", $0) }.joined()
        let designated = designatedString as String
        return LidAwakeCodeIdentity(
            executablePath: resolvedURL.path,
            designatedRequirement: designated,
            requirement: "(\(designated)) and cdhash H\"\(hash)\"",
            codeHash: hash,
            identifier: identifier
        )
    }
}
