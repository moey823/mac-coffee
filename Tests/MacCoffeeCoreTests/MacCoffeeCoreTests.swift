import Darwin
import Foundation
import XCTest
@testable import MacCoffeeCore

final class MacCoffeeCoreTests: XCTestCase {
    func testTimerChoicesAndAbsoluteDeadline() throws {
        XCTAssertEqual(LidAwakeDuration.allCases.map(\.rawValue), [60, 900, 1_800, 3_600, 7_200, 0])
        XCTAssertEqual(LidAwakeDuration(rawValue: 3_600), .minutes60)
        let start = Date(timeIntervalSince1970: 10_000)
        let deadline = try XCTUnwrap(AwakeDeadline.make(startedAt: start, duration: .minutes15))
        XCTAssertEqual(deadline.timeIntervalSince1970, 10_900)
        XCTAssertNil(AwakeDeadline.make(startedAt: start, duration: .unlimited))
        XCTAssertEqual(AwakeDeadline.remaining(until: deadline, now: start.addingTimeInterval(120)), 780)
        XCTAssertEqual(AwakeDeadline.remaining(until: deadline, now: start.addingTimeInterval(2_000)), 0)
    }

    func testCaffeinateTimeoutRoundsUpWithoutResettingDeadline() {
        let deadline = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(AwakeDeadline.timeoutSeconds(until: deadline, now: Date(timeIntervalSince1970: 1_998.2)), 2)
        XCTAssertEqual(AwakeDeadline.timeoutSeconds(until: deadline, now: Date(timeIntervalSince1970: 2_001)), 1)
        let beforeToggle = AwakeDeadline.timeoutSeconds(until: deadline, now: Date(timeIntervalSince1970: 1_990))
        XCTAssertEqual(beforeToggle, 10)
        XCTAssertEqual(deadline.timeIntervalSince1970, 2_000)
    }

    func testCaffeinateArgumentsUseOnlyOwnedProcessAndSelectedAssertions() {
        XCTAssertEqual(CaffeinateCommand.executablePath, "/usr/bin/caffeinate")
        XCTAssertEqual(
            CaffeinateCommand.arguments(ownerPID: 1234, keepsDisplayOn: false, timeoutSeconds: 60),
            ["-i", "-t", "60", "-w", "1234"]
        )
        XCTAssertEqual(
            CaffeinateCommand.arguments(ownerPID: 1234, keepsDisplayOn: true, timeoutSeconds: 60),
            ["-i", "-d", "-t", "60", "-w", "1234"]
        )
        XCTAssertEqual(
            CaffeinateCommand.arguments(ownerPID: 42, keepsDisplayOn: false, timeoutSeconds: nil),
            ["-i", "-w", "42"]
        )
    }

    func testLidAwakeDurationAndOwnershipGuards() {
        XCTAssertFalse(LidAwakeSessionPolicy.accepts(duration: 59))
        XCTAssertTrue(LidAwakeSessionPolicy.accepts(duration: 60))
        XCTAssertTrue(LidAwakeSessionPolicy.accepts(duration: 24 * 60 * 60))
        XCTAssertFalse(LidAwakeSessionPolicy.accepts(duration: 24 * 60 * 60 + 1))
        XCTAssertFalse(LidAwakeSessionPolicy.accepts(duration: .nan))
        XCTAssertTrue(LidAwakeSessionPolicy.accepts(duration: nil))
        XCTAssertEqual(LidAwakeSessionPolicy.startDecision(sleepDisabled: false, hasJournal: false), .begin)
        XCTAssertEqual(LidAwakeSessionPolicy.startDecision(sleepDisabled: false, hasJournal: false, clamshellStateAvailable: false), .clamshellStateUnknown)
        XCTAssertEqual(LidAwakeSessionPolicy.startDecision(sleepDisabled: false, hasJournal: true), .sessionAlreadyOwned)
    }

    func testHeartbeatsNeverExtendTheSelectedDeadlineAndRejectExpiry() {
        var record = makeRecord(duration: 60)
        record.phase = .active
        let wallDeadline = record.deadlineEpoch
        let monotonicDeadline = record.deadlineMonotonic
        for offset in [10.0, 20.0, 30.0, 40.0, 50.0] {
            XCTAssertTrue(LidAwakeSessionPolicy.heartbeat(
                &record,
                nowEpoch: 1_000 + offset,
                nowMonotonic: 10 + offset,
                bootIdentifier: "boot-A",
                auditSessionIdentifier: 42
            ))
            XCTAssertEqual(record.deadlineEpoch, wallDeadline)
            XCTAssertEqual(record.deadlineMonotonic, monotonicDeadline)
        }
        XCTAssertEqual(record.deadlineEpoch, wallDeadline)
        XCTAssertEqual(record.deadlineMonotonic, monotonicDeadline)
        XCTAssertTrue(LidAwakeSessionPolicy.deadlineHasPassed(
            record,
            nowEpoch: 1_060,
            nowMonotonic: 70,
            bootIdentifier: "boot-A"
        ))
    }

    func testHelperRecoveryProtectsBatteryThermalAndHeartbeat() {
        var record = makeRecord(duration: nil)
        record.phase = .active
        XCTAssertEqual(
            LidAwakeSessionPolicy.recoveryAction(
                for: record, sleepDisabled: true, nowEpoch: 1_029.9, nowMonotonic: 39.9,
                bootIdentifier: "boot-A", auditSessionIdentifier: 42, isOnBattery: false,
                batteryPercent: nil, criticalThermalState: false
            ),
            .continueSession
        )
        XCTAssertEqual(
            LidAwakeSessionPolicy.recoveryAction(
                for: record, sleepDisabled: true, nowEpoch: 1_030, nowMonotonic: 40,
                bootIdentifier: "boot-A", auditSessionIdentifier: 42, isOnBattery: false,
                batteryPercent: nil, criticalThermalState: false
            ),
            .restore(reason: .heartbeatExpired, sleepNowIfLidClosed: true)
        )
        XCTAssertEqual(
            LidAwakeSessionPolicy.recoveryAction(
                for: record, sleepDisabled: true, nowEpoch: 1_001, nowMonotonic: 11,
                bootIdentifier: "boot-A", auditSessionIdentifier: 42, isOnBattery: true,
                batteryPercent: 15, criticalThermalState: false
            ),
            .restore(reason: .lowBattery, sleepNowIfLidClosed: true)
        )
        XCTAssertEqual(
            LidAwakeSessionPolicy.recoveryAction(
                for: record, sleepDisabled: true, nowEpoch: 1_001, nowMonotonic: 11,
                bootIdentifier: "boot-A", auditSessionIdentifier: 42, isOnBattery: false,
                batteryPercent: nil, criticalThermalState: true
            ),
            .restore(reason: .criticalThermalState, sleepNowIfLidClosed: true)
        )
    }

    func testClosedLidTimerExpiryRestoresThenRequestsSleep() throws {
        var record = makeRecord(duration: 60)
        record.phase = .active
        XCTAssertEqual(
            LidAwakeSessionPolicy.recoveryAction(
                for: record, sleepDisabled: true, nowEpoch: 1_060, nowMonotonic: 70,
                bootIdentifier: "boot-A", auditSessionIdentifier: 42, isOnBattery: false,
                batteryPercent: nil, criticalThermalState: false
            ),
            .restore(reason: .durationExpired, sleepNowIfLidClosed: true)
        )

        var sleepDisabled = true
        var events: [String] = []
        let result = LidAwakePolicyTransitions.restore(
            record: record,
            sleepNowIfLidClosed: true,
            persist: { _ in true },
            readSleepPolicy: { sleepDisabled },
            applySleepPolicy: { value in events.append("set-\(value)"); sleepDisabled = value },
            verifySleepPolicy: { events.append("verify"); return sleepDisabled },
            lidIsClosed: { true },
            requestSleepNow: { events.append("sleepNow"); XCTAssertFalse(sleepDisabled) },
            removeJournal: { events.append("remove"); return true }
        )
        XCTAssertEqual(result, .restored)
        XCTAssertEqual(events, ["set-false", "verify", "sleepNow", "remove"])
        let restoreIndex = try XCTUnwrap(events.firstIndex(of: "set-false"))
        let verificationIndex = try XCTUnwrap(events.firstIndex(of: "verify"))
        let sleepIndex = try XCTUnwrap(events.firstIndex(of: "sleepNow"))
        XCTAssertLessThan(restoreIndex, verificationIndex)
        XCTAssertLessThan(verificationIndex, sleepIndex)
    }

    func testCodeServiceIdentityIsNewAndBundlePathIsCorrect() {
        XCTAssertEqual(LidAwakeServiceConfiguration.applicationIdentifier, "com.moey823.MacCoffee")
        XCTAssertEqual(LidAwakeServiceConfiguration.serviceLabel, "com.moey823.MacCoffee.LidAwake")
        XCTAssertEqual(LidAwakeServiceConfiguration.helperExecutableName, "MacCoffeeLidAwakeHelper")
        let helper = URL(fileURLWithPath: "/Applications/Mac Coffee.app/Contents/Library/HelperTools/MacCoffeeLidAwakeHelper")
        XCTAssertEqual(
            LidAwakeServiceConfiguration.applicationBundleURL(containingHelperAt: helper).path,
            "/Applications/Mac Coffee.app"
        )
    }

    func testProcessPathReaderResolvesTheCurrentTestProcess() throws {
        let executableURL = try LidAwakeProcessPath.executableURL(for: getpid())

        XCTAssertTrue(executableURL.isFileURL)
        XCTAssertFalse(executableURL.path.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: executableURL.path))
    }

    func testStartDecisionRejectsUnknownOrAlreadyDisabledSleepPolicy() {
        XCTAssertEqual(
            LidAwakeSessionPolicy.startDecision(sleepDisabled: true, hasJournal: false),
            .sleepAlreadyDisabled
        )
        XCTAssertEqual(
            LidAwakeSessionPolicy.startDecision(sleepDisabled: nil, hasJournal: false),
            .sleepPolicyUnknown
        )
    }

    func testHelperRestartRestoresAnOwnedOverrideEvenWithFreshHeartbeat() {
        var record = makeRecord(duration: 3_600)
        record.phase = .active

        XCTAssertEqual(
            LidAwakeSessionPolicy.startupRecoveryAction(
                for: record,
                sleepDisabled: true,
                nowEpoch: 1_005,
                nowMonotonic: 15,
                bootIdentifier: "boot-A"
            ),
            .restore(reason: .helperRestart, sleepNowIfLidClosed: true)
        )
    }

    func testLidAwakeCommandPlanUsesOnlyFixedPMSetArguments() {
        XCTAssertEqual(LidAwakeCommandPlan.executablePath, "/usr/bin/pmset")
        XCTAssertEqual(LidAwakeCommandPlan.setSleepDisabled(true), ["-a", "disablesleep", "1"])
        XCTAssertEqual(LidAwakeCommandPlan.setSleepDisabled(false), ["-a", "disablesleep", "0"])
        XCTAssertEqual(LidAwakeCommandPlan.sleepNow, ["sleepnow"])
    }

    func testActivationVerificationUnknownKeepsJournalAndDoesNotAcknowledge() {
        let record = makeRecord(duration: 60)
        var journaled: LidAwakeSessionRecord?
        var policyWrites: [Bool] = []
        var removals = 0

        let result = LidAwakePolicyTransitions.activate(
            record: record,
            persist: { journaled = $0; return true },
            applySleepPolicy: { policyWrites.append($0) },
            verifySleepPolicy: { nil },
            removeJournal: { removals += 1 }
        )

        XCTAssertEqual(result, .stateUnknown)
        XCTAssertEqual(journaled?.phase, .applying)
        XCTAssertEqual(policyWrites, [true])
        XCTAssertEqual(removals, 0)
    }

    func testRestoreAttemptsFixedDisableWhenRestoreJournalWriteFails() {
        let record = makeRecord(duration: 60)
        var sleepDisabled = true
        var policyWrites: [Bool] = []
        var removals = 0

        let result = LidAwakePolicyTransitions.restore(
            record: record,
            sleepNowIfLidClosed: false,
            persist: { _ in false },
            readSleepPolicy: { sleepDisabled },
            applySleepPolicy: { value in policyWrites.append(value); sleepDisabled = value },
            verifySleepPolicy: { sleepDisabled },
            lidIsClosed: { false },
            requestSleepNow: { XCTFail("An open lid must not request sleepNow.") },
            removeJournal: { removals += 1; return true }
        )

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(policyWrites, [false])
        XCTAssertFalse(sleepDisabled)
        XCTAssertEqual(removals, 1)
    }

    func testRestoreVerificationUnknownRetainsJournalAndDoesNotSleep() {
        let record = makeRecord(duration: 60)
        var removedJournal = false
        var requestedSleep = false

        let result = LidAwakePolicyTransitions.restore(
            record: record,
            sleepNowIfLidClosed: true,
            persist: { _ in true },
            readSleepPolicy: { true },
            applySleepPolicy: { _ in },
            verifySleepPolicy: { nil },
            lidIsClosed: { true },
            requestSleepNow: { requestedSleep = true },
            removeJournal: { removedJournal = true; return true }
        )

        XCTAssertEqual(result, .pending)
        XCTAssertFalse(removedJournal)
        XCTAssertFalse(requestedSleep)
    }

    func testOnlyOwningConnectionCanOwnTheSession() {
        let record = makeRecord(duration: 60)

        XCTAssertTrue(LidAwakePolicyTransitions.ownsSession(record, connectionIdentifier: "gui-connection"))
        XCTAssertFalse(LidAwakePolicyTransitions.ownsSession(record, connectionIdentifier: "status-only-connection"))
    }

    func testOffPresentationUsesRedOutlineWithoutClaimingSavedDisplayPreference() {
        let presentation = CoffeeMenuBarPresentation.make(for: .off, keepsScreenOn: true)

        XCTAssertEqual(presentation.symbolName, "cup.and.saucer")
        XCTAssertEqual(presentation.tint, .red)
        XCTAssertTrue(presentation.accessibilityLabel.contains("off"))
        XCTAssertFalse(presentation.accessibilityLabel.localizedCaseInsensitiveContains("display"))
        XCTAssertFalse(presentation.accessibilityLabel.localizedCaseInsensitiveContains("screen"))
    }

    func testActivePresentationUsesGreenFilledCupAndAccessibleCountdown() {
        let finite = CoffeeMenuBarPresentation.make(
            for: .active(remaining: 3_598.2),
            keepsScreenOn: true
        )
        XCTAssertEqual(finite.symbolName, "cup.and.saucer.fill")
        XCTAssertEqual(finite.tint, .green)
        XCTAssertTrue(finite.accessibilityLabel.contains("59 minutes and 59 seconds remaining"))
        XCTAssertTrue(finite.accessibilityLabel.contains("display is also being kept awake"))

        let unlimited = CoffeeMenuBarPresentation.make(for: .active(remaining: nil), keepsScreenOn: false)
        XCTAssertEqual(unlimited.symbolName, "cup.and.saucer.fill")
        XCTAssertEqual(unlimited.tint, .green)
        XCTAssertTrue(unlimited.accessibilityLabel.contains("until stopped"))
        XCTAssertFalse(unlimited.accessibilityLabel.contains("display"))
    }

    func testTransitionsUseAmberDistinctShapesAndErrorsUseRedWarning() {
        let starting = CoffeeMenuBarPresentation.make(for: .starting, keepsScreenOn: false)
        XCTAssertEqual(starting.symbolName, "hourglass")
        XCTAssertEqual(starting.tint, .amber)
        XCTAssertTrue(starting.accessibilityLabel.contains("starting"))

        let stopping = CoffeeMenuBarPresentation.make(for: .stopping, keepsScreenOn: false)
        XCTAssertEqual(stopping.symbolName, "arrow.uturn.backward.circle")
        XCTAssertEqual(stopping.tint, .amber)
        XCTAssertTrue(stopping.accessibilityLabel.contains("restoring"))

        let error = CoffeeMenuBarPresentation.make(for: .error("Helper approval is required."), keepsScreenOn: true)
        XCTAssertEqual(error.symbolName, "exclamationmark.triangle.fill")
        XCTAssertEqual(error.tint, .red)
        XCTAssertTrue(error.accessibilityLabel.contains("Helper approval is required."))
        XCTAssertFalse(error.symbolName == starting.symbolName)
    }

    private func makeRecord(duration: TimeInterval?) -> LidAwakeSessionRecord {
        LidAwakeSessionRecord(
            durationSeconds: duration,
            startedEpoch: 1_000,
            startedMonotonic: 10,
            bootIdentifier: "boot-A",
            auditSessionIdentifier: 42,
            ownerUserIdentifier: 501,
            ownerConnectionIdentifier: "gui-connection",
            applicationCodeHash: "ABCD"
        )
    }
}
