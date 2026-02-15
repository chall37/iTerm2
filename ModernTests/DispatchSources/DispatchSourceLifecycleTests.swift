//
//  DispatchSourceLifecycleTests.swift
//  ModernTests
//
//  Tests for dispatch source setup, teardown, and idempotent operations.
//

import XCTest
@testable import iTerm2SharedARC

// MARK: - Dispatch Source Lifecycle Tests

/// Tests for dispatch source setup and teardown
final class DispatchSourceLifecycleTests: XCTestCase {

    func testSetupCreatesSourcesWhenFdValid() throws {
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

        XCTAssertFalse(task.testHasReadSource(), "No read source before setup")
        XCTAssertFalse(task.testHasWriteSource(), "No write source before setup")

        task.testSetupDispatchSourcesForTesting()
        task.testWaitForIOQueue()

        XCTAssertTrue(task.testHasReadSource(), "Read source should be created")
        XCTAssertTrue(task.testHasWriteSource(), "Write source should be created")

        // Write source should be suspended (empty buffer)
        XCTAssertTrue(task.testIsWriteSourceSuspended(), "Write source should start suspended (empty buffer)")

        // Read source stays active for EOF detection even while paused
        task.paused = true
        task.testWaitForIOQueue()
        XCTAssertFalse(task.testIsReadSourceSuspended(), "Read source should never be suspended")

        task.testTeardownDispatchSourcesForTesting()
    }

    func testTeardownCleansUpSources() throws {
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

        task.testSetupDispatchSourcesForTesting()
        task.testWaitForIOQueue()

        XCTAssertTrue(task.testHasReadSource(), "Read source should exist after setup")
        XCTAssertTrue(task.testHasWriteSource(), "Write source should exist after setup")

        task.testTeardownDispatchSourcesForTesting()
        task.testWaitForIOQueue()

        XCTAssertFalse(task.testHasReadSource(), "Read source should be nil after teardown")
        XCTAssertFalse(task.testHasWriteSource(), "Write source should be nil after teardown")
    }

    func testUpdateMethodsExist() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        let readSelector = NSSelectorFromString("updateReadSourceState")
        let writeSelector = NSSelectorFromString("updateWriteSourceState")

        XCTAssertTrue(task.responds(to: readSelector),
                      "PTYTask should have updateReadSourceState")
        XCTAssertTrue(task.responds(to: writeSelector),
                      "PTYTask should have updateWriteSourceState")
    }

    func testTeardownIsSafeWithoutSetup() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        XCTAssertFalse(task.testHasReadSource(), "No read source should exist before setup")
        XCTAssertFalse(task.testHasWriteSource(), "No write source should exist before setup")

        let selector = NSSelectorFromString("teardownDispatchSources")
        if task.responds(to: selector) {
            task.perform(selector)
        }

        XCTAssertFalse(task.testHasReadSource(), "No read source after teardown on fresh task")
        XCTAssertFalse(task.testHasWriteSource(), "No write source after teardown on fresh task")
    }

    func testMultipleTeardownCallsSafe() {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        let selector = NSSelectorFromString("teardownDispatchSources")
        guard task.responds(to: selector) else {
            XCTFail("PTYTask should respond to teardownDispatchSources")
            return
        }

        for i in 0..<5 {
            task.perform(selector)
            XCTAssertFalse(task.testHasReadSource(), "No read source after teardown \(i)")
            XCTAssertFalse(task.testHasWriteSource(), "No write source after teardown \(i)")
        }
    }

    func testTeardownWithActiveReadSourceWhilePaused() throws {
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
        task.testSetupDispatchSourcesForTesting()
        task.testWaitForIOQueue()

        // Read source stays active for EOF detection even while paused
        task.paused = true
        task.testWaitForIOQueue()
        XCTAssertFalse(task.testIsReadSourceSuspended(), "Read source should never be suspended")

        // Teardown with active read source while paused - should NOT crash
        task.testTeardownDispatchSourcesForTesting()
        XCTAssertFalse(task.testHasReadSource(), "Read source should be nil after teardown")
    }

    func testTeardownWithSuspendedWriteSource() throws {
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
        task.testSetupDispatchSourcesForTesting()
        task.testWaitForIOQueue()

        XCTAssertTrue(task.testIsWriteSourceSuspended(), "Write source should be suspended with empty buffer")

        // Teardown with suspended write source - should NOT crash
        task.testTeardownDispatchSourcesForTesting()
        XCTAssertFalse(task.testHasWriteSource(), "Write source should be nil after teardown")
    }

    func testTeardownWhilePausedWithActiveReadAndSuspendedWrite() throws {
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
        task.testSetupDispatchSourcesForTesting()
        task.testWaitForIOQueue()

        task.paused = true
        task.testWaitForIOQueue()

        // Read source stays active for EOF detection even while paused
        XCTAssertFalse(task.testIsReadSourceSuspended(), "Read source should never be suspended")
        XCTAssertTrue(task.testIsWriteSourceSuspended(), "Write source should be suspended (empty buffer)")

        // Teardown with active read source and suspended write source - should NOT crash
        task.testTeardownDispatchSourcesForTesting()
        XCTAssertFalse(task.testHasReadSource(), "Read source should be nil after teardown")
        XCTAssertFalse(task.testHasWriteSource(), "Write source should be nil after teardown")
    }

    /// Regression test: closeFileDescriptorAndDeregisterIfPossible must tear down
    /// dispatch sources before the job manager closes the fd. Otherwise the sources
    /// remain active on a potentially reused descriptor.
    func testCloseFileDescriptorTearsDownSourcesFirst() throws {
        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        guard let pipe = createTestPipe() else {
            XCTFail("Failed to create test pipe")
            return
        }
        defer { closeTestPipe(pipe) }

        // testSetFd creates an iTermLegacyJobManager, so set the mock AFTER
        task.testSetFd(pipe.readFd)
        let mockJobManager = MockJobManager()
        mockJobManager.fd = pipe.readFd
        task.testSetJobManager(mockJobManager)
        task.testIoAllowedOverride = NSNumber(value: true)

        task.testSetupDispatchSourcesForTesting()
        task.testWaitForIOQueue()

        XCTAssertTrue(task.testHasReadSource(), "Read source should exist after setup")
        XCTAssertTrue(task.testHasWriteSource(), "Write source should exist after setup")

        // This must tear down sources before closing the fd
        task.closeFileDescriptorAndDeregisterIfPossible()

        XCTAssertFalse(task.testHasReadSource(),
                       "Read source should be torn down after closeFileDescriptorAndDeregisterIfPossible")
        XCTAssertFalse(task.testHasWriteSource(),
                       "Write source should be torn down after closeFileDescriptorAndDeregisterIfPossible")
        XCTAssertEqual(mockJobManager.closeFileDescriptorCallCount, 1,
                       "Job manager closeFileDescriptor should have been called")
    }
}
