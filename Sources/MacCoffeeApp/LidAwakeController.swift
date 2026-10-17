import Combine
import Foundation
import Darwin
import IOKit
import ServiceManagement
import MacCoffeeCore

enum LidAwakeStatus: Equatable {
    case off, starting, active, stopping
    case unavailable(String), error(String)

    var title: String {
        switch self {
        case .off: "Off"
        case .starting: "Starting"
        case .active: "Active"
        case .stopping: "Stopping"
        case .unavailable: "Unavailable"
        case .error: "Error"
        }
    }

    var detail: String {
        switch self {
        case .off: ""
        case .starting: "Waiting for the helper to confirm the session."
        case .active: "The helper confirmed the session is active."
        case .stopping: "Waiting for the helper to restore normal sleep behavior."
        case .unavailable(let message), .error(let message): message
        }
    }
}

enum LidAwakeSetupStatus: Equatable {
    case notRegistered, enabled, requiresApproval
    case error(String)

    var title: String {
        switch self {
        case .notRegistered: "Helper setup needed"
        case .enabled: "Ready"
        case .requiresApproval: "Approval needed"
        case .error: "Setup error"
        }
    }

    var detail: String {
        switch self {
        case .notRegistered: "Helper has not been registered or macOS could not locate it. Register helper to continue, then approve it in macOS Login Items."
        case .enabled: "The helper is registered and approved."
        case .requiresApproval: "Approve the helper in System Settings > General > Login Items."
        case .error(let message): message
        }
    }
}

enum LidAwakeRepairOutcome {
    case ready
    case approvalRequired
    case registeredButUnavailable(String)
    case blocked(String)
    case failed(String)
}

struct LidAwakeDiagnosticSnapshot {
    let setupStatus: LidAwakeSetupStatus
    let observedSessionActive: Bool?
    let detail: String?
}

@MainActor
final class LidAwakeController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var status: LidAwakeStatus = .off
    @Published private(set) var setupStatus: LidAwakeSetupStatus = .notRegistered
    @Published var duration: LidAwakeDuration {
        didSet {
            guard duration != oldValue else { return }
            UserDefaults.standard.set(duration.rawValue, forKey: Self.durationPreferenceKey)
        }
    }
    @Published private(set) var deadline: Date?
    @Published private(set) var remaining: TimeInterval?
    @Published private(set) var error: String?
    @Published private(set) var isRepairing = false

    private static let durationPreferenceKey = "MacCoffee.lidAwakeDurationSeconds"
    private let isPreview: Bool
    private var isRefreshing = false
    private var ownsSession = false
    private var isStopRequestInProgress = false
    private var operationID: UUID?
    private var sessionConnection: NSXPCConnection?
    private var heartbeatTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?

    init(isPreview: Bool = false) {
        self.isPreview = isPreview
        if let savedSeconds = UserDefaults.standard.object(forKey: Self.durationPreferenceKey) as? Int,
           let savedDuration = LidAwakeDuration(rawValue: savedSeconds) {
            duration = savedDuration
        } else {
            duration = .minutes60
        }
        setupStatus = .notRegistered
    }

    func refreshStatus() {
        guard !isPreview, !isRepairing else { return }
        setupStatus = currentSetupStatus()
        guard !ownsSession, !isTransitioning, !isRefreshing else { return }
        isRefreshing = true
        Task { [weak self] in await self?.performStatusRefresh() }
    }

    func refreshStatusAndWaitForDecision() async {
        guard !isPreview, !isRepairing else { return }
        setupStatus = currentSetupStatus()
        guard !ownsSession, !isTransitioning else { return }
        if isRefreshing {
            while isRefreshing {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return
        }
        isRefreshing = true
        await performStatusRefresh()
    }

    func start() {
        guard !isPreview, !isRepairing, !ownsSession, !isTransitioning else { return }
        guard setupStatus == .enabled else {
            status = .unavailable(setupStatus.detail)
            refreshStatus()
            return
        }
        let newOperationID = UUID()
        operationID = newOperationID
        error = nil
        status = .starting
        Task { [weak self] in await self?.performStart(operationID: newOperationID) }
    }

    func stop() {
        guard !isPreview else { return }
        if case .starting = status {
            operationID = nil
            if let connection = sessionConnection { closeSessionConnection(connection) }
            status = .off
            error = nil
            return
        }
        guard ownsSession, let connection = sessionConnection, !isStopRequestInProgress else { return }
        isStopRequestInProgress = true
        let stopOperationID = UUID()
        operationID = stopOperationID
        status = .stopping
        heartbeatTask?.cancel()
        heartbeatTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        Task { [weak self] in
            await self?.performStop(on: connection, operationID: stopOperationID)
        }
    }

    func stopForApplicationShutdown() {
        guard !isPreview, let connection = sessionConnection else { return }
        if ownsSession,
           let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? LidAwakeXPCProtocol {
            proxy.stopSession { _, _ in }
        }
        closeSessionConnection(connection)
        status = .off
        error = nil
    }

    func registerHelper() {
        guard !isPreview, !isRepairing, !ownsSession, !isTransitioning else { return }
        do {
            try SMAppService.daemon(plistName: LidAwakeServiceConfiguration.servicePlistName).register()
            setupStatus = currentSetupStatus()
            status = setupStatus == .enabled ? .off : .unavailable(setupStatus.detail)
            if setupStatus == .enabled { error = nil }
        } catch {
            let latestStatus = currentSetupStatus()
            setupStatus = latestStatus == .requiresApproval ? latestStatus : .error(error.localizedDescription)
            status = .unavailable(setupStatus.detail)
        }
    }

    func repairHelper() async -> LidAwakeRepairOutcome {
        guard !isPreview else { return .blocked("Helper repair is unavailable in preview mode.") }
        guard !isRepairing else { return .blocked("A helper repair is already running.") }
        guard !ownsSession, !isEnabled, !isTransitioning else {
            return .blocked("Stop the current lid-awake session before repairing the helper.")
        }
        guard !isRefreshing else {
            let message = "Wait for the current helper status check to finish before repairing."
            status = .unavailable(message)
            error = message
            return .blocked(message)
        }
        guard packagedHelperFilesArePresent() else {
            let message = "The helper plist or executable is missing from this app bundle."
            status = .unavailable(message)
            error = message
            return .failed(message)
        }

        isRepairing = true
        defer { isRepairing = false }
        error = nil

        if case .unavailable(let previousDetail) = status,
           previousDetail.localizedCaseInsensitiveContains("session is active outside this MacCoffee session") {
            let message = "Repair stopped because an active helper session was previously observed. Refresh status after it ends."
            status = .unavailable(message)
            error = message
            return .blocked(message)
        }

        let beforeRepair = await readOnlyDiagnostic()
        if beforeRepair.observedSessionActive == true {
            let message = beforeRepair.detail ?? "An active helper session was observed. No service changes were made."
            status = .unavailable(message)
            return .blocked(message)
        }

        let service = SMAppService.daemon(plistName: LidAwakeServiceConfiguration.servicePlistName)
        var didUnregisterExistingService = false
        switch service.status {
        case .enabled, .requiresApproval:
            guard let sleepDisabled = readSystemSleepDisabled(), !sleepDisabled else {
                let message = "Repair stopped because macOS could not confirm that system sleep is enabled. No service changes were made."
                status = .unavailable(message)
                error = message
                return .blocked(message)
            }
            do {
                try await service.unregister()
                didUnregisterExistingService = true
            } catch {
                let message = "Could not unregister the existing lid-awake helper: \(error.localizedDescription)"
                setupStatus = currentSetupStatus()
                status = .unavailable(message)
                self.error = message
                return .failed(message)
            }
        case .notRegistered, .notFound:
            guard let sleepDisabled = readSystemSleepDisabled(), !sleepDisabled else {
                let message = "Repair stopped because macOS could not confirm that system sleep is enabled. No service changes were made."
                status = .unavailable(message)
                error = message
                return .blocked(message)
            }
        @unknown default:
            let message = "Repair stopped because macOS returned an unknown helper registration status."
            status = .unavailable(message)
            error = message
            return .blocked(message)
        }

        let retryDelays: [UInt64] = [1_000_000_000, 2_000_000_000]
        var retryCount = 0
        while true {
            do {
                try service.register()
                break
            } catch {
                guard didUnregisterExistingService,
                      retryCount < retryDelays.count,
                      isPermissionDenied(error),
                      isNotRegistered(service.status) else {
                    let message = "Could not register the updated lid-awake helper: \(error.localizedDescription)"
                    setupStatus = currentSetupStatus()
                    status = .unavailable(message)
                    self.error = message
                    return .failed(message)
                }

                do {
                    try await Task.sleep(nanoseconds: retryDelays[retryCount])
                } catch {
                    let message = "Helper registration retry was cancelled."
                    setupStatus = currentSetupStatus()
                    status = .unavailable(message)
                    self.error = message
                    return .failed(message)
                }

                guard isNotRegistered(service.status) else {
                    let message = "Helper registration retry stopped because macOS changed the service state."
                    setupStatus = currentSetupStatus()
                    status = .unavailable(message)
                    self.error = message
                    return .blocked(message)
                }
                guard let sleepDisabled = readSystemSleepDisabled(), !sleepDisabled else {
                    let message = "Helper registration retry stopped because macOS could not confirm that system sleep is enabled."
                    setupStatus = currentSetupStatus()
                    status = .unavailable(message)
                    self.error = message
                    return .blocked(message)
                }
                retryCount += 1
            }
        }

        setupStatus = currentSetupStatus()
        switch setupStatus {
        case .requiresApproval:
            status = .off
            error = nil
            return .approvalRequired
        case .enabled:
            let afterRepair = await readOnlyDiagnostic()
            if afterRepair.observedSessionActive == true {
                let message = afterRepair.detail ?? "The helper is registered, but an active session was observed."
                status = .unavailable(message)
                error = nil
                return .registeredButUnavailable(message)
            }
            if afterRepair.observedSessionActive == false, helperConfirmsNormalSleep(afterRepair.detail) {
                status = .off
                error = nil
                return .ready
            }
            let detail = afterRepair.detail ?? "The helper did not confirm its status."
            let message = "The helper was re-registered, but its status is unavailable: \(detail) No lid-awake session was started."
            status = .unavailable(message)
            error = message
            return .registeredButUnavailable(message)
        case .notRegistered:
            let message = "The helper did not remain registered after repair."
            status = .unavailable(message)
            error = message
            return .failed(message)
        case .error(let detail):
            status = .unavailable(detail)
            error = detail
            return .failed(detail)
        }
    }

    func openLoginItemsSettings() {
        guard !isPreview else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    func readOnlyDiagnostic() async -> LidAwakeDiagnosticSnapshot {
        guard !isPreview else {
            return LidAwakeDiagnosticSnapshot(
                setupStatus: .notRegistered,
                observedSessionActive: nil,
                detail: "Helper status was not read in preview mode."
            )
        }
        let setup = currentSetupStatus()
        guard setup == .enabled else {
            return LidAwakeDiagnosticSnapshot(
                setupStatus: setup,
                observedSessionActive: nil,
                detail: setup.detail
            )
        }

        var connection: NSXPCConnection?
        do {
            let statusConnection = try makeConnection(sessionConnection: false)
            connection = statusConnection
            let reply = try await getStatus(on: statusConnection)
            statusConnection.invalidate()
            return LidAwakeDiagnosticSnapshot(
                setupStatus: setup,
                observedSessionActive: reply.isActive,
                detail: reply.detail
            )
        } catch {
            connection?.invalidate()
            return LidAwakeDiagnosticSnapshot(
                setupStatus: setup,
                observedSessionActive: nil,
                detail: error.localizedDescription
            )
        }
    }

    private var isTransitioning: Bool {
        switch status {
        case .starting, .stopping: true
        case .off, .active, .unavailable, .error: false
        }
    }

    private func currentSetupStatus() -> LidAwakeSetupStatus {
        guard packagedHelperFilesArePresent() else {
            return .error("The helper launch daemon plist or executable is missing from this app bundle.")
        }
        let service = SMAppService.daemon(plistName: LidAwakeServiceConfiguration.servicePlistName)
        return switch service.status {
        case .notRegistered, .notFound: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        @unknown default: .error("macOS returned an unknown helper registration status.")
        }
    }

    private func isPermissionDenied(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        for _ in 0..<5 {
            guard let candidate = current else { return false }
            if candidate.domain == NSPOSIXErrorDomain, candidate.code == Int(EPERM) {
                return true
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private func isNotRegistered(_ status: SMAppService.Status) -> Bool {
        switch status {
        case .notRegistered, .notFound:
            true
        default:
            false
        }
    }

    private func packagedHelperFilesArePresent() -> Bool {
        let launchDaemonsURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
        let plistURL = launchDaemonsURL
            .appendingPathComponent(LidAwakeServiceConfiguration.servicePlistName, isDirectory: false)
        let helperURL = LidAwakeServiceConfiguration.helperExecutableURL(in: Bundle.main.bundleURL)
        return FileManager.default.fileExists(atPath: plistURL.path)
            && FileManager.default.isExecutableFile(atPath: helperURL.path)
    }

    private func readSystemSleepDisabled() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            service,
            "SleepDisabled" as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return nil
        }
        let value = unmanaged.takeRetainedValue()
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "yes", "true", "1": return true
            case "no", "false", "0": return false
            default: return nil
            }
        }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private func performStatusRefresh() async {
        defer { isRefreshing = false }
        let latestSetup = currentSetupStatus()
        setupStatus = latestSetup
        guard latestSetup == .enabled else {
            if !ownsSession && !isTransitioning { status = .unavailable(latestSetup.detail) }
            return
        }
        guard !ownsSession, !isTransitioning else { return }

        var connection: NSXPCConnection?
        do {
            let statusConnection = try makeConnection(sessionConnection: false)
            connection = statusConnection
            let reply = try await getStatus(on: statusConnection)
            statusConnection.invalidate()
            connection = nil
            guard !ownsSession, !isTransitioning else { return }
            if reply.isActive {
                status = .unavailable(reply.detail ?? "A lid-awake session is active outside this MacCoffee session. It will not be adopted.")
            } else if helperConfirmsNormalSleep(reply.detail) {
                status = .off
                error = nil
            } else {
                status = .unavailable(reply.detail ?? "The helper could not confirm that normal sleep behavior is restored.")
            }
        } catch {
            connection?.invalidate()
            if !ownsSession && !isTransitioning {
                status = .unavailable("Could not contact the lid-awake helper: \(error.localizedDescription)")
            }
        }
    }

    private func helperConfirmsNormalSleep(_ detail: String?) -> Bool {
        detail == "No lid-awake session is active." || detail == "System sleep is enabled."
    }

    private func performStart(operationID requestedOperationID: UUID) async {
        let latestSetup = currentSetupStatus()
        setupStatus = latestSetup
        guard latestSetup == .enabled else {
            guard operationID == requestedOperationID else { return }
            status = .unavailable(latestSetup.detail)
            return
        }

        do {
            let connection = try makeConnection(sessionConnection: true)
            sessionConnection = connection
            let reply = try await startSession(on: connection)
            guard operationID == requestedOperationID, sessionConnection === connection else {
                connection.invalidate()
                return
            }
            guard reply.isActive else {
                let message = reply.detail ?? "The helper did not accept the lid-awake session."
                closeSessionConnection(connection)
                error = message
                status = .error(message)
                return
            }

            ownsSession = true
            isEnabled = true
            error = nil
            deadline = reply.deadline ?? duration.seconds.map { Date().addingTimeInterval($0) }
            status = .active
            updateRemaining()
            startSessionTimers(on: connection)
        } catch {
            guard operationID == requestedOperationID else { return }
            if let connection = sessionConnection { closeSessionConnection(connection) }
            let message = "Could not start lid-awake: \(error.localizedDescription)"
            isEnabled = false
            deadline = nil
            remaining = nil
            ownsSession = false
            self.error = message
            status = .error(message)
        }
    }

    private func performStop(on connection: NSXPCConnection, operationID requestedOperationID: UUID) async {
        do {
            let reply = try await stopSession(on: connection)
            guard operationID == requestedOperationID, sessionConnection === connection else { return }
            closeSessionConnection(connection)
            if reply.stopped {
                error = nil
                status = .off
            } else {
                let message = reply.detail ?? "The helper could not confirm that normal sleep behavior was restored."
                error = message
                status = .error(message)
            }
        } catch {
            guard operationID == requestedOperationID, sessionConnection === connection else { return }
            let message = "Could not stop lid-awake cleanly: \(error.localizedDescription)"
            closeSessionConnection(connection)
            self.error = message
            status = .error(message)
        }
    }

    private func startSessionTimers(on connection: NSXPCConnection) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self, weak connection] in
            guard let self, let connection else { return }
            await self.heartbeatLoop(on: connection)
        }
        countdownTask?.cancel()
        guard deadline != nil else {
            remaining = nil
            countdownTask = nil
            return
        }
        countdownTask = Task { [weak self, weak connection] in
            guard let self, let connection else { return }
            while !Task.isCancelled {
                self.updateRemaining()
                if self.sessionConnection !== connection || !self.ownsSession { return }
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch { return }
            }
        }
    }

    private func heartbeatLoop(on connection: NSXPCConnection) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 7_000_000_000)
            } catch { return }
            guard !Task.isCancelled, ownsSession, !isStopRequestInProgress, sessionConnection === connection else { return }
            do {
                let reply = try await heartbeat(on: connection)
                guard ownsSession, !isStopRequestInProgress, sessionConnection === connection else { return }
                guard reply.isActive else {
                    if let deadline, deadline <= Date() {
                        stop()
                    } else {
                        failSession(reply.detail ?? "The helper ended the lid-awake session.", connection: connection)
                    }
                    return
                }
                if let replyDeadline = reply.deadline { deadline = replyDeadline }
                updateRemaining()
            } catch {
                guard ownsSession, !isStopRequestInProgress, sessionConnection === connection else { return }
                failSession("Lost contact with the lid-awake helper: \(error.localizedDescription)", connection: connection)
                return
            }
        }
    }

    private func updateRemaining() {
        guard let deadline else {
            remaining = nil
            return
        }
        let timeLeft = max(0, deadline.timeIntervalSinceNow)
        remaining = timeLeft
        if timeLeft == 0, case .active = status {
            status = .stopping
            stop()
        }
    }

    private func makeConnection(sessionConnection isSessionConnection: Bool) throws -> NSXPCConnection {
        let helperURL = LidAwakeServiceConfiguration.helperExecutableURL(in: Bundle.main.bundleURL)
        let identity = try LidAwakeCodeIdentityReader.read(executableURL: helperURL)
        let connection = NSXPCConnection(
            machServiceName: LidAwakeServiceConfiguration.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: LidAwakeXPCProtocol.self)
        connection.setCodeSigningRequirement(identity.requirement)
        if isSessionConnection {
            connection.interruptionHandler = { [weak self, weak connection] in
                guard let connection else { return }
                Task { @MainActor [weak self] in
                    self?.failSession("The lid-awake helper connection was interrupted.", connection: connection)
                }
            }
            connection.invalidationHandler = { [weak self, weak connection] in
                guard let connection else { return }
                Task { @MainActor [weak self] in
                    self?.failSession("The lid-awake helper connection ended unexpectedly.", connection: connection)
                }
            }
        }
        connection.resume()
        return connection
    }

    private func getStatus(on connection: NSXPCConnection) async throws -> LidAwakeReply {
        try await request(operation: "read status", on: connection) { proxy, finish in
            proxy.getStatus { active, deadline, detail in
                finish(.success(LidAwakeReply(isActive: active, deadline: deadline, detail: detail)))
            }
        }
    }

    private func startSession(on connection: NSXPCConnection) async throws -> LidAwakeReply {
        let durationSeconds = duration.seconds.map { NSNumber(value: $0) }
        return try await request(operation: "start the session", on: connection) { proxy, finish in
            proxy.startSession(durationSeconds: durationSeconds) { active, deadline, detail in
                finish(.success(LidAwakeReply(isActive: active, deadline: deadline, detail: detail)))
            }
        }
    }

    private func heartbeat(on connection: NSXPCConnection) async throws -> LidAwakeReply {
        try await request(operation: "send a heartbeat", on: connection) { proxy, finish in
            proxy.heartbeat { active, deadline, detail in
                finish(.success(LidAwakeReply(isActive: active, deadline: deadline, detail: detail)))
            }
        }
    }

    private func stopSession(on connection: NSXPCConnection) async throws -> LidAwakeStopReply {
        try await request(operation: "stop the session", on: connection) { proxy, finish in
            proxy.stopSession { stopped, detail in
                finish(.success(LidAwakeStopReply(stopped: stopped, detail: detail)))
            }
        }
    }

    private func request<Value>(
        operation: String,
        on connection: NSXPCConnection,
        perform: @escaping (LidAwakeXPCProtocol, @escaping (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
            let gate = ContinuationGate<Value>(continuation)
            let timeoutItem = DispatchWorkItem {
                gate.resolve(.failure(LidAwakeControllerFailure.timeout(operation)))
            }
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + 5, execute: timeoutItem)
            let complete: (Result<Value, Error>) -> Void = { result in
                timeoutItem.cancel()
                gate.resolve(result)
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                complete(.failure(error))
            }) as? LidAwakeXPCProtocol else {
                complete(.failure(LidAwakeControllerFailure.proxyUnavailable))
                return
            }
            perform(proxy, complete)
        }
    }

    private func failSession(_ message: String, connection: NSXPCConnection) {
        guard sessionConnection === connection else { return }
        closeSessionConnection(connection)
        error = message
        status = .error(message)
    }

    private func closeSessionConnection(_ connection: NSXPCConnection) {
        guard sessionConnection === connection else {
            connection.invalidate()
            return
        }
        sessionConnection = nil
        operationID = nil
        ownsSession = false
        isEnabled = false
        isStopRequestInProgress = false
        deadline = nil
        remaining = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        connection.interruptionHandler = nil
        connection.invalidationHandler = nil
        connection.invalidate()
    }
}

private struct LidAwakeReply {
    let isActive: Bool
    let deadline: Date?
    let detail: String?

    init(isActive: Bool, deadline: NSNumber?, detail: String?) {
        self.isActive = isActive
        self.deadline = deadline.map { Date(timeIntervalSince1970: $0.doubleValue) }
        self.detail = detail
    }
}

private struct LidAwakeStopReply {
    let stopped: Bool
    let detail: String?
}

private enum LidAwakeControllerFailure: LocalizedError {
    case timeout(String)
    case proxyUnavailable

    var errorDescription: String? {
        switch self {
        case .timeout(let operation): "The helper did not respond in time to \(operation)."
        case .proxyUnavailable: "The helper did not provide its XPC interface."
        }
    }
}

private final class ContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
