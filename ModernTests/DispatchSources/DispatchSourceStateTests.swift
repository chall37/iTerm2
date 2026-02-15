//
//  DispatchSourceStateTests.swift
//  ModernTests
//
//  State predicate and pause/unpause transition tests for dispatch sources.
//

import XCTest
@testable import iTerm2SharedARC

// MARK: - Read State Predicate Tests

/// Tests for wantsRead predicate behavior
final class DispatchSourceReadStateTests: XCTestCase {

    func testWantsReadMethodExists() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        XCTAssertTrue(task.responds(to: #selector(getter: task.wantsRead)),
                      "PTYTask should have wantsRead property")
    }

    func testWantsReadFalseWhenPaused() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        task.paused = true
        XCTAssertFalse(task.wantsRead, "wantsRead should return false when paused")
    }

    func testWantsReadChangesWithPauseState() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        task.paused = true
        XCTAssertFalse(task.wantsRead, "wantsRead should be false when paused=true")

        task.paused = false
        // wantsRead being true also requires ioAllowed
        // We can only verify that pausing definitely makes it false
    }

    func testUpdateReadSourceStateSafeWithoutSources() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        XCTAssertFalse(task.testHasReadSource(), "No read source before update")

        let selector = NSSelectorFromString("updateReadSourceState")
        guard task.responds(to: selector) else {
            XCTFail("PTYTask should respond to updateReadSourceState")
            return
        }

        for _ in 0..<3 {
            task.perform(selector)
        }

        XCTAssertFalse(task.testHasReadSource(), "updateReadSourceState should not create source")
    }
}

// MARK: - Write State Predicate Tests

/// Tests for wantsWrite predicate behavior
final class DispatchSourceWriteStateTests: XCTestCase {

    func testWantsWriteMethodExists() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        XCTAssertTrue(task.responds(to: #selector(getter: task.wantsWrite)),
                      "PTYTask should have wantsWrite property")
    }

    func testWantsWriteFalseWhenPaused() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        task.paused = true
        XCTAssertFalse(task.wantsWrite, "wantsWrite should return false when paused")
    }

    func testWantsWriteFalseWhenBufferEmpty() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        task.paused = false
        XCTAssertFalse(task.wantsWrite, "wantsWrite should be false with empty buffer")
    }

    func testShouldWriteOverrideProperty() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        XCTAssertFalse(task.testShouldWriteOverride, "Override should initially be false")

        task.testShouldWriteOverride = true
        XCTAssertTrue(task.testShouldWriteOverride, "Override should be settable to true")

        task.testShouldWriteOverride = false
        XCTAssertFalse(task.testShouldWriteOverride, "Override should be resettable to false")

        // Test that override affects wantsWrite with buffer data
        task.testShouldWriteOverride = true
        task.testIoAllowedOverride = NSNumber(value: true)
        task.paused = false

        let testData = "Test data".data(using: .utf8)!
        task.testAppendData(toWriteBuffer: testData)
        XCTAssertTrue(task.testWriteBufferHasData(), "Buffer should have data after append")
        XCTAssertTrue(task.wantsWrite, "wantsWrite should be true with override and data in buffer")

        task.testShouldWriteOverride = false
    }

    func testUpdateWriteSourceStateSafeWithoutSources() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        XCTAssertFalse(task.testHasWriteSource(), "No write source before update")

        let selector = NSSelectorFromString("updateWriteSourceState")
        guard task.responds(to: selector) else {
            XCTFail("PTYTask should respond to updateWriteSourceState")
            return
        }

        for _ in 0..<3 {
            task.perform(selector)
        }

        XCTAssertFalse(task.testHasWriteSource(), "updateWriteSourceState should not create source")
    }
}

// MARK: - Pause State Tests

/// Tests for pause state affecting dispatch source suspend/resume
final class DispatchSourcePauseStateTests: XCTestCase {

    func testPausedPropertyExists() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        let initialPaused = task.paused
        task.paused = !initialPaused
        XCTAssertEqual(task.paused, !initialPaused, "paused property should be settable")
        task.paused = initialPaused
        XCTAssertEqual(task.paused, initialPaused, "paused property should round-trip")
    }

    func testPauseAffectsWantsRead() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        task.paused = true
        XCTAssertFalse(task.wantsRead, "wantsRead should be false when paused")
    }

    func testPauseAffectsWantsWrite() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        task.paused = true
        XCTAssertFalse(task.wantsWrite, "wantsWrite should be false when paused")
    }

    func testReadSourceStaysActiveThroughPauseCycles() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        guard let pipe = createTestPipe() else {
            XCTFail("Failed to create test pipe")
            return
        }
        defer { closeTestPipe(pipe) }

        task.testSetFd(pipe.readFd)
        task.paused = true

        task.testSetupDispatchSourcesForTesting()
        task.testWaitForIOQueue()

        // Read source stays active for EOF detection even while paused
        XCTAssertFalse(task.testIsReadSourceSuspended(), "Read source should never be suspended")

        task.paused = false
        task.testWaitForIOQueue()
        XCTAssertFalse(task.testIsReadSourceSuspended(), "Read source should never be suspended")

        task.paused = true
        task.testWaitForIOQueue()
        XCTAssertFalse(task.testIsReadSourceSuspended(), "Read source should never be suspended")

        task.testTeardownDispatchSourcesForTesting()
    }

    func testReadSourceNeverSuspendedAcrossPauseUnpause() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        guard let pipe = createTestPipe() else {
            XCTFail("Failed to create test pipe")
            return
        }
        defer { closeTestPipe(pipe) }

        task.testSetFd(pipe.readFd)
        task.paused = false

        task.testSetupDispatchSourcesForTesting()
        task.testWaitForIOQueue()

        XCTAssertFalse(task.testIsReadSourceSuspended(), "Read source should never be suspended")

        // Read source stays active for EOF detection even while paused
        task.paused = true
        task.testWaitForIOQueue()
        XCTAssertFalse(task.testIsReadSourceSuspended(), "Read source should never be suspended")

        task.paused = false
        task.testWaitForIOQueue()
        XCTAssertFalse(task.testIsReadSourceSuspended(), "Read source should never be suspended")

        task.testTeardownDispatchSourcesForTesting()
    }

    func testPauseUnpauseCycle() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        task.paused = true
        XCTAssertTrue(task.paused)
        XCTAssertFalse(task.wantsRead, "wantsRead should be false when paused")

        task.paused = false
        XCTAssertFalse(task.paused)
    }

    func testRapidPauseUnpauseCycle() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        for _ in 0..<100 {
            task.paused = true
            task.paused = false
        }
        XCTAssertFalse(task.paused, "Should end in unpaused state")
    }

    func testUpdateMethodsIdempotent() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        let readSelector = NSSelectorFromString("updateReadSourceState")
        let writeSelector = NSSelectorFromString("updateWriteSourceState")

        guard task.responds(to: readSelector) && task.responds(to: writeSelector) else {
            XCTFail("PTYTask should respond to update methods")
            return
        }

        let initialHasReadSource = task.testHasReadSource()
        let initialHasWriteSource = task.testHasWriteSource()

        for _ in 0..<20 {
            task.perform(readSelector)
            task.perform(writeSelector)
        }

        XCTAssertEqual(task.testHasReadSource(), initialHasReadSource,
                       "Read source state should remain stable")
        XCTAssertEqual(task.testHasWriteSource(), initialHasWriteSource,
                       "Write source state should remain stable")
    }
}

// MARK: - ioAllowed Predicate Tests

/// Tests for ioAllowed affecting wantsRead/wantsWrite predicates
final class DispatchSourceIoAllowedTests: XCTestCase {

    func testIoAllowedOverridePropertyExists() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        XCTAssertNil(task.testIoAllowedOverride, "testIoAllowedOverride should be nil by default")

        task.testIoAllowedOverride = NSNumber(value: true)
        XCTAssertEqual(task.testIoAllowedOverride?.boolValue, true)

        task.testIoAllowedOverride = NSNumber(value: false)
        XCTAssertEqual(task.testIoAllowedOverride?.boolValue, false)

        task.testIoAllowedOverride = nil
        XCTAssertNil(task.testIoAllowedOverride)
    }

    func testWantsReadFalseWhenIoAllowedFalse() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        task.paused = false
        task.testIoAllowedOverride = NSNumber(value: false)

        XCTAssertFalse(task.wantsRead, "wantsRead should be false when ioAllowed=false")
    }

    func testWantsReadTrueWhenIoAllowedTrueAndNotPaused() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        task.paused = false
        task.testIoAllowedOverride = NSNumber(value: true)

        XCTAssertTrue(task.wantsRead, "wantsRead should be true when ioAllowed=true and not paused")
    }

    func testWantsReadFlipsWhenIoAllowedChanges() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        task.paused = false

        task.testIoAllowedOverride = NSNumber(value: true)
        XCTAssertTrue(task.wantsRead, "wantsRead should be true when ioAllowed=true")

        task.testIoAllowedOverride = NSNumber(value: false)
        XCTAssertFalse(task.wantsRead, "wantsRead should flip to false when ioAllowed flips to false")

        task.testIoAllowedOverride = NSNumber(value: true)
        XCTAssertTrue(task.wantsRead, "wantsRead should flip back to true")
    }

    func testIoAllowedFalseOverridesPausedFalse() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        task.paused = false
        task.testIoAllowedOverride = NSNumber(value: false)

        XCTAssertFalse(task.wantsRead, "ioAllowed=false should make wantsRead=false regardless of paused state")
    }

    func testIoAllowedTrueDoesNotOverridePausedTrue() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        task.paused = true
        task.testIoAllowedOverride = NSNumber(value: true)

        XCTAssertFalse(task.wantsRead, "paused=true should make wantsRead=false regardless of ioAllowed")
    }

    func testReadSourceStaysActiveWhenIoAllowedBecomesFalse() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        guard let pipe = createTestPipe() else {
            XCTFail("Failed to create test pipe")
            return
        }
        defer { closeTestPipe(pipe) }

        task.testSetFd(pipe.readFd)
        task.paused = false
        task.testIoAllowedOverride = NSNumber(value: true)

        task.testSetupDispatchSourcesForTesting()
        task.testWaitForIOQueue()

        // Read source stays active for EOF detection even when ioAllowed changes
        XCTAssertFalse(task.testIsReadSourceSuspended(), "Read source should never be suspended")

        task.testIoAllowedOverride = NSNumber(value: false)
        task.perform(NSSelectorFromString("updateReadSourceState"))
        task.testWaitForIOQueue()

        XCTAssertFalse(task.testIsReadSourceSuspended(), "Read source should never be suspended")

        task.testTeardownDispatchSourcesForTesting()
    }

    func testReadSourceStaysActiveWhenIoAllowedBecomesTrue() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        guard let pipe = createTestPipe() else {
            XCTFail("Failed to create test pipe")
            return
        }
        defer { closeTestPipe(pipe) }

        task.testSetFd(pipe.readFd)
        task.paused = false
        task.testIoAllowedOverride = NSNumber(value: false)

        task.testSetupDispatchSourcesForTesting()
        task.testWaitForIOQueue()

        // Read source stays active for EOF detection regardless of ioAllowed
        XCTAssertFalse(task.testIsReadSourceSuspended(), "Read source should never be suspended")

        task.testIoAllowedOverride = NSNumber(value: true)
        task.perform(NSSelectorFromString("updateReadSourceState"))
        task.testWaitForIOQueue()

        XCTAssertFalse(task.testIsReadSourceSuspended(), "Read source should never be suspended")

        task.testTeardownDispatchSourcesForTesting()
    }

    func testWriteSourceSuspendsWhenIoAllowedBecomesFalse() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        guard let pipe = createTestPipe() else {
            XCTFail("Failed to create test pipe")
            return
        }
        defer { closeTestPipe(pipe) }

        task.testSetFd(pipe.writeFd)
        task.paused = false
        task.testIoAllowedOverride = NSNumber(value: true)
        let testData = "Test data for write".data(using: .utf8)!
        task.testAppendData(toWriteBuffer: testData)

        task.testSetupDispatchSourcesForTesting()
        task.testWaitForIOQueue()

        XCTAssertFalse(task.testIsWriteSourceSuspended(),
                       "Write source should be resumed with ioAllowed=true and data in buffer")

        task.testIoAllowedOverride = NSNumber(value: false)
        task.perform(NSSelectorFromString("updateWriteSourceState"))
        task.testWaitForIOQueue()

        XCTAssertTrue(task.testIsWriteSourceSuspended(),
                      "Write source should SUSPEND when ioAllowed becomes false")

        task.testTeardownDispatchSourcesForTesting()
    }

    func testWriteSourceResumesWhenIoAllowedBecomesTrue() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        guard let pipe = createTestPipe() else {
            XCTFail("Failed to create test pipe")
            return
        }
        defer { closeTestPipe(pipe) }

        task.testSetFd(pipe.writeFd)
        task.paused = false
        task.testIoAllowedOverride = NSNumber(value: false)
        let testData = "Test data for write".data(using: .utf8)!
        task.testAppendData(toWriteBuffer: testData)

        task.testSetupDispatchSourcesForTesting()
        task.testWaitForIOQueue()

        XCTAssertTrue(task.testIsWriteSourceSuspended(),
                      "Write source should be suspended with ioAllowed=false")

        task.testIoAllowedOverride = NSNumber(value: true)
        task.perform(NSSelectorFromString("updateWriteSourceState"))
        task.testWaitForIOQueue()

        XCTAssertFalse(task.testIsWriteSourceSuspended(),
                       "Write source should RESUME when ioAllowed becomes true")

        task.testTeardownDispatchSourcesForTesting()
    }

    func testWriteSourceStaysSuspendedWithoutData() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        guard let pipe = createTestPipe() else {
            XCTFail("Failed to create test pipe")
            return
        }
        defer { closeTestPipe(pipe) }

        task.testSetFd(pipe.writeFd)
        task.paused = false
        task.testIoAllowedOverride = NSNumber(value: true)
        task.testShouldWriteOverride = true

        task.testSetupDispatchSourcesForTesting()
        task.testWaitForIOQueue()

        XCTAssertTrue(task.testIsWriteSourceSuspended(),
                      "Write source should stay suspended without data in buffer")

        let testData = "Test data".data(using: .utf8)!
        task.testAppendData(toWriteBuffer: testData)
        task.perform(NSSelectorFromString("updateWriteSourceState"))
        task.testWaitForIOQueue()

        XCTAssertFalse(task.testIsWriteSourceSuspended(),
                       "Write source should resume after data is added to buffer")

        task.testTeardownDispatchSourcesForTesting()
    }

    func testWriteSourceSuspendsWhenPausedBecomesTrue() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        guard let pipe = createTestPipe() else {
            XCTFail("Failed to create test pipe")
            return
        }
        defer { closeTestPipe(pipe) }

        task.testSetFd(pipe.writeFd)
        task.paused = false
        task.testIoAllowedOverride = NSNumber(value: true)
        task.testShouldWriteOverride = true
        let testData = "Test data".data(using: .utf8)!
        task.testAppendData(toWriteBuffer: testData)

        task.testSetupDispatchSourcesForTesting()
        task.testWaitForIOQueue()

        XCTAssertFalse(task.testIsWriteSourceSuspended(),
                       "Write source should be resumed when unpaused with data")

        task.paused = true
        task.testWaitForIOQueue()

        XCTAssertTrue(task.testIsWriteSourceSuspended(),
                      "Write source should SUSPEND when paused becomes true")

        task.testTeardownDispatchSourcesForTesting()
    }

    func testWantsWriteFalseWhenIoAllowedFalse() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        task.paused = false
        let testData = "Test data".data(using: .utf8)!
        task.testAppendData(toWriteBuffer: testData)
        XCTAssertTrue(task.testWriteBufferHasData(), "Buffer should have data")

        task.testIoAllowedOverride = NSNumber(value: false)
        XCTAssertFalse(task.wantsWrite, "wantsWrite should be false when ioAllowed=false")
    }

    func testWantsWriteTrueWhenAllConditionsMet() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        task.paused = false
        task.testShouldWriteOverride = true

        let testData = "Test data".data(using: .utf8)!
        task.testAppendData(toWriteBuffer: testData)
        XCTAssertTrue(task.testWriteBufferHasData(), "Buffer should have data")

        task.testIoAllowedOverride = NSNumber(value: true)
        XCTAssertTrue(task.wantsWrite, "wantsWrite should be true when all conditions met")

        task.testShouldWriteOverride = false
    }
}
