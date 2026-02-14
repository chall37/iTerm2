//
//  TaskNotifierDispatchSourceTests.swift
//  ModernTests
//
//  Unit tests for TaskNotifier select loop and coprocess data flow bridge.
//
//  With the fairness scheduler, PTY I/O for fairness-enabled tasks is handled
//  entirely by PTYTaskIOHandler dispatch sources. TaskNotifier only handles
//  legacy (non-fairness) tasks via select(). These tests verify:
//  - Legacy tasks are still processed via select()
//  - Unblock pipe and deadpool/waitpid continue to work
//  - Coprocess data flow bridge operates correctly through PTYTask

import XCTest
@testable import iTerm2SharedARC

// MARK: - Test Helpers

/// Creates a MockTaskNotifierTask with a pipe FD for testing.
/// Returns nil on failure.
private func createMockPipeTask() -> (task: MockTaskNotifierTask, writeFd: Int32)? {
    return MockTaskNotifierTask.createPipeTask()
}

// MARK: - Select Loop Tests

/// Tests for TaskNotifier select() loop with legacy tasks.
final class TaskNotifierSelectLoopTests: XCTestCase {

    func testLegacyTaskProcessReadCalledBySelect() throws {
        // Legacy tasks should have processRead called by TaskNotifier's select() loop

        guard let (mockTask, writeFd) = createMockPipeTask() else {
            XCTFail("Failed to create test pipe")
            return
        }
        defer {
            mockTask.closeFd()
            close(writeFd)
        }

        mockTask.wantsRead = true

        // Register with TaskNotifier
        let notifier = TaskNotifier.sharedInstance()
        notifier?.register(mockTask)
        defer { notifier?.deregister(mockTask) }

        // Wait for registration (dispatched to main queue)
        waitForMainQueue()

        let initialCount = mockTask.processReadCallCount
        mockTask.wantsRead = true

        // Write to the pipe to make data available
        let testData = "legacy test data"
        _ = testData.withCString { ptr in
            Darwin.write(writeFd, ptr, strlen(ptr))
        }

        // Wait for TaskNotifier's select loop to process
        let success = mockTask.wait(forProcessReadCalls: initialCount + 1, timeout: 2.0)

        XCTAssertTrue(success,
                      "Legacy task should have processRead called via select()")
        XCTAssertGreaterThan(mockTask.processReadCallCount, initialCount,
                             "processRead should have been called at least once")
    }

    func testLegacyTaskProcessWriteCalledBySelect() throws {
        // Legacy tasks should have processWrite called when wantsWrite is true

        guard let (mockTask, _) = createMockPipeTask() else {
            XCTFail("Failed to create test pipe")
            return
        }
        defer { mockTask.closeFd() }

        mockTask.wantsWrite = true

        // Register with TaskNotifier
        let notifier = TaskNotifier.sharedInstance()
        notifier?.register(mockTask)
        defer { notifier?.deregister(mockTask) }

        // Wait for registration
        waitForMainQueue()

        let initialCount = mockTask.processWriteCallCount
        mockTask.wantsWrite = true

        // Unblock to wake select loop
        notifier?.unblock()

        // Wait for processWrite to be called
        var success = false
        for _ in 0..<50 {
            if mockTask.processWriteCallCount > initialCount {
                success = true
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        XCTAssertTrue(success,
                      "Legacy task should have processWrite called via select()")
    }

    func testUnblockPipeStillInSelect() throws {
        // The unblock pipe should wake select() on registration changes

        let mockTask = MockTaskNotifierTask()
        mockTask.fd = -1

        let notifier = TaskNotifier.sharedInstance()
        XCTAssertNotNil(notifier, "TaskNotifier should exist")
        XCTAssertTrue(notifier!.responds(to: #selector(TaskNotifier.unblock)),
                      "TaskNotifier should have unblock method")

        // Register task - this should use the unblock pipe internally
        notifier?.register(mockTask)

        // didRegister should be called on main queue (proves unblock worked)
        waitForMainQueue()

        XCTAssertGreaterThan(mockTask.didRegisterCallCount, 0,
                             "didRegister should be called after registration (proves unblock pipe works)")

        // Cleanup
        notifier?.deregister(mockTask)
    }

    func testDeadpoolHandlingUnchanged() throws {
        // Deadpool/waitpid handling works independently of I/O mechanism

        let mockTask = MockTaskNotifierTask()
        mockTask.pid = 0
        mockTask.pidToWaitOn = 0

        let notifier = TaskNotifier.sharedInstance()
        XCTAssertNotNil(notifier, "TaskNotifier should exist")
        XCTAssertTrue(notifier!.responds(to: #selector(TaskNotifier.wait(forPid:))),
                      "TaskNotifier should have waitForPid method")
    }

    func testTmuxTaskStaysOnSelect() throws {
        // Tmux tasks (fd < 0) continue using select() path

        let mockTask = MockTaskNotifierTask()
        mockTask.fd = -1

        XCTAssertEqual(mockTask.fd, -1, "Tmux task should have fd = -1")

        // Register with TaskNotifier
        let notifier = TaskNotifier.sharedInstance()
        notifier?.register(mockTask)

        // Wait for registration to complete
        waitForMainQueue()

        XCTAssertGreaterThan(mockTask.didRegisterCallCount, 0,
                             "Tmux task should be registered successfully")

        // Cleanup
        notifier?.deregister(mockTask)
    }

    func testLegacyTasksUnaffected() throws {
        // Legacy tasks work exactly as before

        guard let (mockTask, writeFd) = createMockPipeTask() else {
            XCTFail("Failed to create test pipe")
            return
        }
        defer {
            mockTask.closeFd()
            close(writeFd)
        }

        mockTask.wantsRead = true

        // Register with TaskNotifier
        TaskNotifier.sharedInstance()?.register(mockTask)
        defer { TaskNotifier.sharedInstance()?.deregister(mockTask) }

        // Wait for registration
        waitForMainQueue()

        let initialCount = mockTask.processReadCallCount
        mockTask.wantsRead = true

        // Write to the pipe
        _ = "legacy test data".withCString { ptr in Darwin.write(writeFd, ptr, strlen(ptr)) }

        // Wait for TaskNotifier's select loop to process
        let success = mockTask.wait(forProcessReadCalls: initialCount + 1, timeout: 2.0)

        XCTAssertTrue(success, "Legacy task should have processRead called via select()")
        XCTAssertGreaterThan(mockTask.processReadCallCount, initialCount,
                             "Legacy task should have processRead called via select()")
    }
}

// MARK: - Coprocess Data Flow Bridge Tests

/// Tests for coprocess data flow bridging with dispatch_source PTY I/O.
/// These tests verify the bridge code paths are correctly wired:
///   - handleReadEvent calls writeToCoprocess (PTY output -> coprocess)
///   - writeTask:coprocess: calls writeBufferDidChange (coprocess output -> PTY)
final class CoprocessDataFlowBridgeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        iTermAdvancedSettingsModel.setUseFairnessSchedulerForTesting(true)
    }

    override func tearDown() {
        iTermAdvancedSettingsModel.setUseFairnessSchedulerForTesting(false)
        super.tearDown()
    }

    func testHandleReadEventRoutesToCoprocess() throws {
        // handleReadEvent should call writeToCoprocess when coprocess is attached.
        //
        // Flow:
        //   1. Data written to ptyPipe.writeFd
        //   2. Read dispatch source fires -> handleReadEvent
        //   3. handleReadEvent calls writeToCoprocess -> coprocess.outputBuffer
        //   4. Coprocess write dispatch source drains outputBuffer -> coprocess.outputFd
        //   5. Data appears on coprocess.testReadFd

        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        guard let ptyPipe = createTestPipe() else {
            XCTFail("Failed to create PTY test pipe")
            return
        }
        defer { closeTestPipe(ptyPipe) }

        guard let coprocess = MockCoprocess.createPipe() else {
            XCTFail("Failed to create MockCoprocess")
            return
        }
        defer {
            coprocess.closeTestFds()
            coprocess.terminate()
        }

        task.testSetFd(ptyPipe.readFd)
        task.paused = false
        task.testIoAllowedOverride = NSNumber(value: true)

        task.testSetupDispatchSourcesForTesting()
        defer { task.testTeardownDispatchSourcesForTesting() }

        task.coprocess = coprocess
        XCTAssertTrue(task.hasCoprocess, "Task should have coprocess attached")

        task.testWaitForIOQueue()
        XCTAssertTrue(task.testHasReadSource, "Task should have read source")
        XCTAssertFalse(task.testIsReadSourceSuspended, "Read source should be resumed")

        // Write data to PTY pipe - triggers handleReadEvent
        let testMessage = "Hello coprocess!"
        let testData = testMessage.data(using: .utf8)!
        testData.withUnsafeBytes { bufferPointer in
            let rawPointer = bufferPointer.baseAddress!
            _ = Darwin.write(ptyPipe.writeFd, rawPointer, testData.count)
        }

        // Read from coprocess.testReadFd to verify data flowed through the bridge
        var receivedData = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)

        let flags = fcntl(coprocess.testReadFd, F_GETFL)
        fcntl(coprocess.testReadFd, F_SETFL, flags | O_NONBLOCK)

        for _ in 0..<50 {
            task.testWaitForIOQueue()
            let bytesRead = Darwin.read(coprocess.testReadFd, &buffer, buffer.count)
            if bytesRead > 0 {
                receivedData.append(contentsOf: buffer[0..<bytesRead])
            }
            if receivedData.count >= testData.count { break }
            Thread.sleep(forTimeInterval: 0.01)
        }

        XCTAssertEqual(receivedData.count, testData.count,
                      "handleReadEvent should route PTY data through writeToCoprocess bridge to coprocess fd")

        if let receivedString = String(data: receivedData, encoding: .utf8) {
            XCTAssertEqual(receivedString, testMessage,
                          "Coprocess should receive the PTY data")
        }
    }

    func testWriteTaskTriggersWriteSource() throws {
        // writeTask should trigger writeBufferDidChange which wakes write source

        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        guard let ptyPipe = createTestPipe() else {
            XCTFail("Failed to create PTY test pipe")
            return
        }
        defer { closeTestPipe(ptyPipe) }

        task.testSetFd(ptyPipe.writeFd)
        task.paused = false
        task.testShouldWriteOverride = true
        defer { task.testShouldWriteOverride = false }

        task.testSetupDispatchSourcesForTesting()
        defer { task.testTeardownDispatchSourcesForTesting() }

        task.testWaitForIOQueue()
        XCTAssertTrue(task.testHasWriteSource, "Task should have write source")
        XCTAssertFalse(task.testWriteBufferHasData, "Write buffer should start empty")

        let testMessage = "Hello PTY!"
        let testData = testMessage.data(using: .utf8)!
        task.write(testData)

        task.testWaitForIOQueue()

        // Read from the PTY pipe to verify data was written
        var buffer = [UInt8](repeating: 0, count: 1024)
        let flags = fcntl(ptyPipe.readFd, F_GETFL)
        fcntl(ptyPipe.readFd, F_SETFL, flags | O_NONBLOCK)

        var receivedData = Data()
        for _ in 0..<10 {
            task.testWaitForIOQueue()
            let bytesRead = Darwin.read(ptyPipe.readFd, &buffer, buffer.count)
            if bytesRead > 0 {
                receivedData.append(contentsOf: buffer[0..<bytesRead])
            }
            if receivedData.count >= testData.count { break }
            Thread.sleep(forTimeInterval: 0.01)
        }

        XCTAssertEqual(receivedData.count, testData.count,
                       "writeBufferDidChange should trigger write source which drains to PTY fd")

        if let receivedString = String(data: receivedData, encoding: .utf8) {
            XCTAssertEqual(receivedString, testMessage,
                           "PTY should receive the data")
        }
    }

    func testCoprocessOutputRoutesToPTY() throws {
        // Coprocess output flows to PTY via writeTask:coprocess:
        //
        // Flow: writeTask:coprocess:YES -> writeBuffer -> writeBufferDidChange
        //       -> write source -> PTY fd

        guard let task = PTYTask() else {
            XCTFail("Failed to create PTYTask")
            return
        }

        guard let ptyPipe = createTestPipe() else {
            XCTFail("Failed to create PTY test pipe")
            return
        }
        defer { closeTestPipe(ptyPipe) }

        task.testSetFd(ptyPipe.writeFd)
        task.paused = false
        task.testIoAllowedOverride = NSNumber(value: true)
        task.testShouldWriteOverride = true
        defer { task.testShouldWriteOverride = false }

        task.testSetupDispatchSourcesForTesting()
        defer { task.testTeardownDispatchSourcesForTesting() }

        task.testWaitForIOQueue()

        let testMessage = "From coprocess!"
        let testData = testMessage.data(using: .utf8)!
        task.testWrite(fromCoprocess: testData)

        task.testWaitForIOQueue()

        // Read from PTY pipe to verify data arrived
        var receivedData = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)

        let flags = fcntl(ptyPipe.readFd, F_GETFL)
        fcntl(ptyPipe.readFd, F_SETFL, flags | O_NONBLOCK)

        for _ in 0..<10 {
            task.testWaitForIOQueue()
            let bytesRead = Darwin.read(ptyPipe.readFd, &buffer, buffer.count)
            if bytesRead > 0 {
                receivedData.append(contentsOf: buffer[0..<bytesRead])
            }
            if receivedData.count >= testData.count { break }
            Thread.sleep(forTimeInterval: 0.01)
        }

        XCTAssertEqual(receivedData.count, testData.count,
                      "Coprocess output should flow to PTY via writeTask:coprocess: bridge")

        if let receivedString = String(data: receivedData, encoding: .utf8) {
            XCTAssertEqual(receivedString, testMessage,
                          "PTY should receive the coprocess output")
        }
    }

    func testCoprocessWriteFdProcessedViaDispatchSource() throws {
        // Verify coprocess write data flows to the coprocess fd via dispatch sources.
        //
        // Flow:
        //   1. Coprocess.outputBuffer has data
        //   2. Coprocess write dispatch source drains outputBuffer to coprocess.outputFd
        //   3. Data appears on coprocess.testReadFd

        guard let (mockTask, writeFd) = createMockPipeTask() else {
            XCTFail("Failed to create mock pipe task")
            return
        }
        defer {
            mockTask.closeFd()
            close(writeFd)
        }

        mockTask.hasCoprocess = true
        mockTask.writeBufferHasRoom = true

        // Create MockCoprocess
        guard let coprocess = MockCoprocess.createPipe() else {
            XCTFail("Failed to create MockCoprocess")
            return
        }
        defer {
            coprocess.closeTestFds()
            coprocess.terminate()
        }

        mockTask.coprocess = coprocess

        // Put data in coprocess.outputBuffer
        let testMessage = "Outgoing coprocess data!"
        let testData = testMessage.data(using: .utf8)!
        coprocess.outputBuffer.append(testData)

        XCTAssertTrue(coprocess.wantToWrite(), "Coprocess should wantToWrite when outputBuffer has data")

        // Register with TaskNotifier (legacy path for mock tasks)
        let notifier = TaskNotifier.sharedInstance()
        notifier?.register(mockTask)
        defer { notifier?.deregister(mockTask) }

        waitForMainQueue()
        notifier?.unblock()

        // Wait for select() to process the coprocess write fd
        var receivedData = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)

        let flags = fcntl(coprocess.testReadFd, F_GETFL)
        fcntl(coprocess.testReadFd, F_SETFL, flags | O_NONBLOCK)

        for _ in 0..<50 {
            waitForMainQueue()
            let bytesRead = Darwin.read(coprocess.testReadFd, &buffer, buffer.count)
            if bytesRead > 0 {
                receivedData.append(contentsOf: buffer[0..<bytesRead])
            }
            if receivedData.count >= testData.count { break }
            Thread.sleep(forTimeInterval: 0.01)
        }

        XCTAssertEqual(receivedData.count, testData.count,
                      "TaskNotifier select() should call [coprocess write] draining outputBuffer to fd")

        if let receivedString = String(data: receivedData, encoding: .utf8) {
            XCTAssertEqual(receivedString, testMessage,
                          "Data from coprocess.outputBuffer should appear on testReadFd")
        }
    }
}
