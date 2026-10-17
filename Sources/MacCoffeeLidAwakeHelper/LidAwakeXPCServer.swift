import Darwin
import Foundation
import Security
import MacCoffeeCore

struct LidAwakeClientAuthorizer {
    let applicationIdentity: LidAwakeCodeIdentity
    let applicationBundleURL: URL

    func permits(_ connection: NSXPCConnection) -> Bool {
        guard connection.processIdentifier > 1,
              let consoleUID = LidAwakePlatform.consoleUserIdentifier(),
              UInt32(connection.effectiveUserIdentifier) == consoleUID,
              bundleOwnerIsTrusted(consoleUID: consoleUID),
              processPath(connection.processIdentifier) == applicationIdentity.executablePath,
              guestCodeMatches(connection.processIdentifier) else {
            return false
        }
        return true
    }

    private func bundleOwnerIsTrusted(consoleUID: UInt32) -> Bool {
        var info = stat()
        guard stat(applicationBundleURL.path, &info) == 0 else { return false }
        let owner = UInt32(info.st_uid)
        return owner == 0 || owner == consoleUID
    }

    private func processPath(_ pid: Int32) -> String? {
        try? LidAwakeProcessPath.executableURL(for: pid).path
    }

    private func guestCodeMatches(_ pid: Int32) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            applicationIdentity.requirement as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess, let requirement else {
            return false
        }
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &guestCode) == errSecSuccess,
              let guestCode else {
            return false
        }
        return SecCodeCheckValidity(guestCode, SecCSFlags(), requirement) == errSecSuccess
    }
}

private final class LidAwakeXPCSession: NSObject, LidAwakeXPCProtocol {
    private let coordinator: LidAwakeSessionCoordinator
    private let connectionIdentifier: String
    private let auditSessionIdentifier: UInt32
    private let ownerUserIdentifier: UInt32
    private let applicationCodeHash: String

    init(
        coordinator: LidAwakeSessionCoordinator,
        connectionIdentifier: String,
        auditSessionIdentifier: UInt32,
        ownerUserIdentifier: UInt32,
        applicationCodeHash: String
    ) {
        self.coordinator = coordinator
        self.connectionIdentifier = connectionIdentifier
        self.auditSessionIdentifier = auditSessionIdentifier
        self.ownerUserIdentifier = ownerUserIdentifier
        self.applicationCodeHash = applicationCodeHash
    }

    func getStatus(reply: @escaping (Bool, NSNumber?, String?) -> Void) {
        let status = coordinator.status()
        reply(status.isActive, status.deadlineEpoch.map(NSNumber.init(value:)), status.detail)
    }

    func startSession(durationSeconds: NSNumber?, reply: @escaping (Bool, NSNumber?, String?) -> Void) {
        let result = coordinator.startSession(
            durationSeconds: durationSeconds?.doubleValue,
            ownerConnectionIdentifier: connectionIdentifier,
            auditSessionIdentifier: auditSessionIdentifier,
            ownerUserIdentifier: ownerUserIdentifier,
            applicationCodeHash: applicationCodeHash
        )
        reply(result.0, result.1.map(NSNumber.init(value:)), result.2)
    }

    func stopSession(reply: @escaping (Bool, String?) -> Void) {
        let result = coordinator.stopSession(ownerConnectionIdentifier: connectionIdentifier)
        reply(result.0, result.1)
    }

    func heartbeat(reply: @escaping (Bool, NSNumber?, String?) -> Void) {
        let result = coordinator.heartbeat(
            ownerConnectionIdentifier: connectionIdentifier,
            auditSessionIdentifier: auditSessionIdentifier
        )
        reply(result.0, result.1.map(NSNumber.init(value:)), result.2)
    }
}

final class LidAwakeXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let coordinator: LidAwakeSessionCoordinator
    private let authorizer: LidAwakeClientAuthorizer
    private let applicationCodeHash: String

    init(
        coordinator: LidAwakeSessionCoordinator,
        authorizer: LidAwakeClientAuthorizer,
        applicationCodeHash: String
    ) {
        self.coordinator = coordinator
        self.authorizer = authorizer
        self.applicationCodeHash = applicationCodeHash
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard authorizer.permits(newConnection),
              let consoleUID = LidAwakePlatform.consoleUserIdentifier() else {
            return false
        }
        let connectionIdentifier = UUID().uuidString
        let exportedObject = LidAwakeXPCSession(
            coordinator: coordinator,
            connectionIdentifier: connectionIdentifier,
            auditSessionIdentifier: UInt32(truncatingIfNeeded: newConnection.auditSessionIdentifier),
            ownerUserIdentifier: consoleUID,
            applicationCodeHash: applicationCodeHash
        )
        newConnection.exportedInterface = NSXPCInterface(with: LidAwakeXPCProtocol.self)
        newConnection.exportedObject = exportedObject
        newConnection.invalidationHandler = { [weak coordinator] in
            coordinator?.connectionInvalidated(identifier: connectionIdentifier)
        }
        newConnection.resume()
        return true
    }
}

final class LidAwakeXPCServer {
    private let listener: NSXPCListener
    private let delegate: LidAwakeXPCListenerDelegate

    init(
        coordinator: LidAwakeSessionCoordinator,
        applicationBundleURL: URL,
        applicationIdentity: LidAwakeCodeIdentity
    ) {
        let authorizer = LidAwakeClientAuthorizer(
            applicationIdentity: applicationIdentity,
            applicationBundleURL: applicationBundleURL
        )
        self.delegate = LidAwakeXPCListenerDelegate(
            coordinator: coordinator,
            authorizer: authorizer,
            applicationCodeHash: applicationIdentity.codeHash
        )
        self.listener = NSXPCListener(machServiceName: LidAwakeServiceConfiguration.machServiceName)
        self.listener.setConnectionCodeSigningRequirement(applicationIdentity.requirement)
        self.listener.delegate = delegate
    }

    func start() {
        listener.resume()
    }
}
