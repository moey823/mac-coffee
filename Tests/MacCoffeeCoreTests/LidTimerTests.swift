import Foundation
import XCTest
@testable import MacCoffeeCore

final class LidTimerTests: XCTestCase {
    func testCustomWholeMinuteDurationsIncludeSevenMinutesAndPreserveLegacyPresets() throws {
        let sevenMinutes = try XCTUnwrap(LidAwakeDuration(minutes: 7))

        XCTAssertEqual(sevenMinutes.rawValue, 420)
        XCTAssertEqual(sevenMinutes.seconds, 420)
        XCTAssertEqual(sevenMinutes.minutes, 7)
        XCTAssertEqual(sevenMinutes.title, "7 minutes")
        XCTAssertEqual(LidAwakeDuration.allCases.map(\.rawValue), [60, 900, 1_800, 3_600, 7_200, 0])
        XCTAssertEqual(LidAwakeDuration(rawValue: 420), sevenMinutes)
        XCTAssertEqual(LidAwakeDuration(minutes: 0), .unlimited)
        XCTAssertEqual(LidAwakeDuration(minutes: 1), .minutes1)
        XCTAssertEqual(LidAwakeDuration(minutes: 1_440)?.seconds, 86_400)
        XCTAssertNil(LidAwakeDuration(minutes: -1))
        XCTAssertNil(LidAwakeDuration(minutes: 1_441))
        XCTAssertNil(LidAwakeDuration(rawValue: 421))
        XCTAssertTrue(LidAwakeSessionPolicy.accepts(duration: 420))
        XCTAssertFalse(LidAwakeSessionPolicy.accepts(duration: 419))
    }

    func testFirstLidCloseStartsSevenMinuteDeadlineOnce() throws {
        var record = makeRecord(duration: 420, startOnLidClose: true, lidIsClosed: false)

        XCTAssertTrue(record.isWaitingForLidClose)
        XCTAssertNil(record.deadlineEpoch)
        XCTAssertNil(record.deadlineMonotonic)
        XCTAssertFalse(LidAwakeSessionPolicy.observeLidClose(
            &record, lidIsClosed: false, nowEpoch: 1_900, nowMonotonic: 100
        ))

        XCTAssertTrue(LidAwakeSessionPolicy.observeLidClose(
            &record, lidIsClosed: true, nowEpoch: 2_000, nowMonotonic: 110
        ))
        XCTAssertFalse(record.isWaitingForLidClose)
        XCTAssertEqual(record.deadlineEpoch, 2_420)
        XCTAssertEqual(record.deadlineMonotonic, 530)

        XCTAssertFalse(LidAwakeSessionPolicy.observeLidClose(
            &record, lidIsClosed: false, nowEpoch: 2_100, nowMonotonic: 210
        ))
        XCTAssertFalse(LidAwakeSessionPolicy.observeLidClose(
            &record, lidIsClosed: true, nowEpoch: 2_200, nowMonotonic: 310
        ))
        XCTAssertEqual(record.deadlineEpoch, 2_420)
        XCTAssertEqual(record.deadlineMonotonic, 530)
    }

    func testArmedTimerWaitsForCloseButStillEnforcesHeartbeatTimeout() {
        var record = makeRecord(duration: 420, startOnLidClose: true, lidIsClosed: false)

        XCTAssertFalse(LidAwakeSessionPolicy.deadlineHasPassed(
            record, nowEpoch: 99_999, nowMonotonic: 99_009, bootIdentifier: "boot-A"
        ))
        XCTAssertTrue(LidAwakeSessionPolicy.heartbeat(
            &record, nowEpoch: 1_010, nowMonotonic: 20, bootIdentifier: "boot-A", auditSessionIdentifier: 42
        ))
        XCTAssertNil(record.deadlineEpoch)
        XCTAssertNil(record.deadlineMonotonic)

        XCTAssertEqual(
            LidAwakeSessionPolicy.recoveryAction(
                for: record, sleepDisabled: true, nowEpoch: 1_040, nowMonotonic: 50,
                bootIdentifier: "boot-A", auditSessionIdentifier: 42, isOnBattery: false,
                batteryPercent: nil, criticalThermalState: false, lidIsClosed: false
            ),
            .restore(reason: .heartbeatExpired, sleepNowIfLidClosed: true)
        )
    }

    func testWaitingSessionStillStopsForLowBatteryThermalAndUnplug() {
        let armed = makeRecord(duration: 420, startOnLidClose: true, lidIsClosed: false)

        XCTAssertEqual(
            recovery(armed, isOnBattery: true, batteryPercent: 15),
            .restore(reason: .lowBattery, sleepNowIfLidClosed: true)
        )
        XCTAssertEqual(
            recovery(armed, isOnBattery: false, criticalThermalState: true),
            .restore(reason: .criticalThermalState, sleepNowIfLidClosed: true)
        )

        let stopOnBattery = makeRecord(
            duration: 420, startOnLidClose: true, stopOnBattery: true, lidIsClosed: false
        )
        XCTAssertEqual(
            recovery(stopOnBattery, isOnBattery: true),
            .restore(reason: .unplugged, sleepNowIfLidClosed: true)
        )
        XCTAssertEqual(
            recovery(stopOnBattery, isOnBattery: nil),
            .restore(reason: .powerSourceUnknown, sleepNowIfLidClosed: true)
        )
        XCTAssertEqual(
            recovery(armed, isOnBattery: false, lidIsClosed: nil),
            .restore(reason: .lidStateUnknown, sleepNowIfLidClosed: false)
        )
    }

    func testAlreadyClosedTimerStartsImmediatelyAndPersistenceKeepsArmedState() throws {
        let alreadyClosed = makeRecord(duration: 420, startOnLidClose: true, lidIsClosed: true)
        XCTAssertFalse(alreadyClosed.isWaitingForLidClose)
        XCTAssertEqual(alreadyClosed.deadlineEpoch, 1_420)
        XCTAssertEqual(alreadyClosed.deadlineMonotonic, 430)

        var record = makeRecord(duration: 420, startOnLidClose: true, lidIsClosed: false)
        let armedRoundTrip = try JSONDecoder().decode(
            LidAwakeSessionRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertTrue(armedRoundTrip.isWaitingForLidClose)
        XCTAssertNil(armedRoundTrip.deadlineEpoch)

        record = armedRoundTrip
        XCTAssertTrue(LidAwakeSessionPolicy.observeLidClose(
            &record, lidIsClosed: true, nowEpoch: 2_000, nowMonotonic: 110
        ))
        let triggeredRoundTrip = try JSONDecoder().decode(
            LidAwakeSessionRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertFalse(triggeredRoundTrip.isWaitingForLidClose)
        XCTAssertEqual(triggeredRoundTrip.deadlineEpoch, 2_420)
        XCTAssertEqual(triggeredRoundTrip.deadlineMonotonic, 530)
    }

    func testSevenMinuteCloseExpiryRestoresSleepThenSleepsOnlyWhenClosed() {
        var record = makeRecord(duration: 420, startOnLidClose: true, lidIsClosed: false)
        XCTAssertTrue(LidAwakeSessionPolicy.observeLidClose(
            &record, lidIsClosed: true, nowEpoch: 2_000, nowMonotonic: 110
        ))
        // Model the helper's periodic heartbeats; the lid-close deadline itself stays fixed.
        record.lastHeartbeatEpoch = 2_410
        record.lastHeartbeatMonotonic = 520

        XCTAssertEqual(
            recovery(
                record,
                nowEpoch: 2_419,
                nowMonotonic: 529,
                isOnBattery: false,
                lidIsClosed: true
            ),
            .continueSession
        )
        XCTAssertEqual(
            recovery(
                record,
                nowEpoch: 2_420,
                nowMonotonic: 530,
                isOnBattery: false,
                lidIsClosed: true
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
            verifySleepPolicy: { sleepDisabled },
            lidIsClosed: { true },
            requestSleepNow: { events.append("sleepNow"); XCTAssertFalse(sleepDisabled) },
            removeJournal: { events.append("remove"); return true }
        )
        XCTAssertEqual(result, .restored)
        XCTAssertEqual(events, ["set-false", "sleepNow", "remove"])

        var openLidEvents: [String] = []
        let openLidResult = LidAwakePolicyTransitions.restore(
            record: record,
            sleepNowIfLidClosed: true,
            persist: { _ in true },
            readSleepPolicy: { true },
            applySleepPolicy: { _ in },
            verifySleepPolicy: { false },
            lidIsClosed: { false },
            requestSleepNow: { openLidEvents.append("sleepNow") },
            removeJournal: { openLidEvents.append("remove"); return true }
        )
        XCTAssertEqual(openLidResult, .restored)
        XCTAssertEqual(openLidEvents, ["remove"])
    }

    func testLegacyJournalWithoutNewPolicyFieldsStillDecodes() throws {
        let data = Data(#"""
        {
          "sessionID": "legacy-session",
          "durationSeconds": 60,
          "startedEpoch": 1000,
          "startedMonotonic": 10,
          "deadlineEpoch": 1060,
          "deadlineMonotonic": 70,
          "lastHeartbeatEpoch": 1000,
          "lastHeartbeatMonotonic": 10,
          "bootIdentifier": "boot-A",
          "auditSessionIdentifier": 42,
          "ownerUserIdentifier": 501,
          "ownerConnectionIdentifier": "gui-connection",
          "applicationCodeHash": "ABCD",
          "phase": "active",
          "sleepNowOnRestore": false,
          "sleepNowIssued": false
        }
        """#.utf8)

        let record = try JSONDecoder().decode(LidAwakeSessionRecord.self, from: data)
        XCTAssertNil(record.startOnLidClose)
        XCTAssertNil(record.stopOnBattery)
        XCTAssertNil(record.lidCloseTriggered)
        XCTAssertFalse(record.isWaitingForLidClose)
        XCTAssertTrue(LidAwakeSessionPolicy.deadlineHasPassed(
            record, nowEpoch: 1_060, nowMonotonic: 70, bootIdentifier: "boot-A"
        ))
    }

    private func makeRecord(
        duration: TimeInterval?,
        startOnLidClose: Bool = false,
        stopOnBattery: Bool = false,
        lidIsClosed: Bool? = true
    ) -> LidAwakeSessionRecord {
        LidAwakeSessionRecord(
            durationSeconds: duration,
            startedEpoch: 1_000,
            startedMonotonic: 10,
            bootIdentifier: "boot-A",
            auditSessionIdentifier: 42,
            ownerUserIdentifier: 501,
            ownerConnectionIdentifier: "gui-connection",
            applicationCodeHash: "ABCD",
            phase: .active,
            startOnLidClose: startOnLidClose,
            stopOnBattery: stopOnBattery,
            lidIsClosed: lidIsClosed
        )
    }

    private func recovery(
        _ record: LidAwakeSessionRecord,
        nowEpoch: TimeInterval = 1_001,
        nowMonotonic: TimeInterval = 11,
        isOnBattery: Bool?,
        batteryPercent: Double? = nil,
        criticalThermalState: Bool = false,
        lidIsClosed: Bool? = false
    ) -> LidAwakeRecoveryAction {
        LidAwakeSessionPolicy.recoveryAction(
            for: record,
            sleepDisabled: true,
            nowEpoch: nowEpoch,
            nowMonotonic: nowMonotonic,
            bootIdentifier: "boot-A",
            auditSessionIdentifier: 42,
            isOnBattery: isOnBattery,
            batteryPercent: batteryPercent,
            criticalThermalState: criticalThermalState,
            lidIsClosed: lidIsClosed
        )
    }
}
