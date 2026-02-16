import Foundation

/// Bytes per read chunk, matching MAXRW in PTYTask.m.
private let kMaxReadWrite: Int = 1024

// MARK: - Delegate Protocol

/// Delegate protocol for PTYTaskIOHandler. PTYTask implements this to bridge
/// dispatch source events back to its internal state.
///
/// Predicate methods are called from any queue and must be thread-safe.
/// Event methods are called on the handler's ioQueue.
@objc protocol PTYTaskIOHandlerDelegate: AnyObject {
    // MARK: State predicates (any queue, thread-safe)

    /// Whether reading should be enabled. Checks paused, ioAllowed, backpressure.
    func ioHandlerShouldRead(_ handler: PTYTaskIOHandler) -> Bool

    /// Whether writing should be enabled. Checks paused, ioAllowed, buffer has data.
    func ioHandlerShouldWrite(_ handler: PTYTaskIOHandler) -> Bool

    /// Whether the coprocess read source should be resumed.
    func ioHandlerShouldResumeCoprocessRead(_ handler: PTYTaskIOHandler) -> Bool

    /// Whether the coprocess write source should be resumed.
    func ioHandlerShouldResumeCoprocessWrite(_ handler: PTYTaskIOHandler) -> Bool

    // MARK: PTY read events (ioQueue)

    /// Data was read from the PTY file descriptor.
    func ioHandler(_ handler: PTYTaskIOHandler, didReadData buffer: UnsafePointer<CChar>, length: Int32)

    /// A broken pipe (EOF or fatal read error) was detected on the PTY fd.
    func ioHandlerDidDetectBrokenPipe(_ handler: PTYTaskIOHandler)

    // MARK: PTY write events (ioQueue)

    /// The write source fired; drain the write buffer now.
    func ioHandlerDrainWriteBuffer(_ handler: PTYTaskIOHandler)

    // MARK: Coprocess events (ioQueue)

    /// The coprocess read source fired. Delegate should read from the coprocess,
    /// handle EOF, and route data as needed.
    func ioHandlerHandleCoprocessRead(_ handler: PTYTaskIOHandler)

    /// The coprocess write source fired. Delegate should flush coprocess output buffer.
    func ioHandlerHandleCoprocessWrite(_ handler: PTYTaskIOHandler)
}

// MARK: - PTYTaskIOHandler

/// Manages dispatch sources for PTY I/O in the fairness scheduler path.
///
/// Owns the ioQueue, read/write dispatch sources, and coprocess dispatch sources.
/// All source event handlers run on the serial ioQueue. The delegate (PTYTask)
/// provides state predicates and receives event callbacks.
///
/// This class has no dependency on TaskNotifier.
@objc class PTYTaskIOHandler: NSObject {

    @objc weak var delegate: PTYTaskIOHandlerDelegate?

    /// The PTY file descriptor. Set at init, immutable.
    private let fd: Int32

    /// Serial queue for all dispatch source handlers.
    let ioQueue: DispatchQueue
    private let ioQueueKey = DispatchSpecificKey<Void>()

    // MARK: Primary dispatch sources

    // Access on ioQueue only (after start)
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?

    // Access on ioQueue only
    private var readSourceSuspended = true
    private var writeSourceSuspended = true

    // MARK: Coprocess dispatch sources

    // Access on ioQueue only (after setupCoprocessSources)
    private var coprocessReadSource: DispatchSourceRead?
    private var coprocessWriteSource: DispatchSourceWrite?

    // Access on ioQueue only
    private var coprocessReadSourceSuspended = false
    private var coprocessWriteSourceSuspended = false

    // MARK: - Init

    @objc init(fd: Int32) {
        precondition(fd >= 0, "PTYTaskIOHandler requires a valid fd")
        self.fd = fd
        self.ioQueue = DispatchQueue(label: "com.iterm2.pty-io")
        super.init()
        ioQueue.setSpecific(key: ioQueueKey, value: ())
    }

    // MARK: - Lifecycle

    /// Main queue. Creates read and write dispatch sources on the fd.
    /// Sources start suspended; updateReadSourceState/updateWriteSourceState
    /// resume them if conditions allow.
    @objc func start() {
        // Read source — starts suspended, resumed by updateReadSourceState when
        // delegate says reading is allowed. Provides backpressure by suspending
        // when the token pipeline is full.
        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        rs.setEventHandler { [weak self] in
            self?.handleReadEvent()
        }
        rs.resume()   // Must resume before we can suspend
        rs.suspend()  // Start suspended
        readSource = rs
        readSourceSuspended = true

        // Write source
        let ws = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: ioQueue)
        ws.setEventHandler { [weak self] in
            self?.handleWriteEvent()
        }
        ws.resume()
        ws.suspend()
        writeSource = ws
        writeSourceSuspended = true

        // Initial state sync
        updateReadSourceState()
        updateWriteSourceState()
    }

    /// Any queue. Tears down all sources (primary + coprocess).
    /// Must resume suspended sources before canceling per GCD rules.
    @objc func teardown() {
        // Also tear down coprocess sources — they share ioQueue.
        teardownCoprocessSources()

        let rs = readSource
        let ws = writeSource

        // Clear source references first - prevents updateReadSourceState/updateWriteSourceState
        // from dispatching any NEW blocks (they check source != nil).
        readSource = nil
        writeSource = nil

        guard rs != nil || ws != nil else { return }

        if isOnIOQueue {
            // Already on ioQueue - teardown inline.
            cancelSource(rs, suspended: readSourceSuspended)
            cancelSource(ws, suspended: writeSourceSuspended)
        } else {
            // Capture suspend state, then teardown synchronously.
            var rSuspended = false
            var wSuspended = false
            ioQueue.sync {
                rSuspended = self.readSourceSuspended
                wSuspended = self.writeSourceSuspended
            }
            ioQueue.sync {
                self.cancelSource(rs, suspended: rSuspended)
                self.cancelSource(ws, suspended: wSuspended)
            }
        }
    }

    // MARK: - State Updates (any queue)

    /// Snapshots shouldRead from delegate, dispatches to ioQueue for source suspend/resume.
    @objc func updateReadSourceState() {
        guard let rs = readSource else { return }
        let shouldRead = delegate?.ioHandlerShouldRead(self) ?? false
        ioQueue.async { [weak self] in
            guard let self else { return }
            if shouldRead && self.readSourceSuspended && self.readSource != nil {
                rs.resume()
                self.readSourceSuspended = false
            } else if !shouldRead && !self.readSourceSuspended && self.readSource != nil {
                rs.suspend()
                self.readSourceSuspended = true
            }
        }
    }

    /// Snapshots shouldWrite from delegate, dispatches to ioQueue for source suspend/resume.
    @objc func updateWriteSourceState() {
        guard let ws = writeSource else { return }
        let shouldWrite = delegate?.ioHandlerShouldWrite(self) ?? false
        ioQueue.async { [weak self] in
            guard let self else { return }
            if shouldWrite && self.writeSourceSuspended && self.writeSource != nil {
                ws.resume()
                self.writeSourceSuspended = false
            } else if !shouldWrite && !self.writeSourceSuspended && self.writeSource != nil {
                ws.suspend()
                self.writeSourceSuspended = true
            }
        }
    }

    /// Any queue. Called when data is added to the write buffer.
    @objc func writeBufferDidChange() {
        updateWriteSourceState()
    }

    // MARK: - Coprocess Source Management

    /// Sets up coprocess dispatch sources for the given file descriptors.
    /// Requires start() to have been called first (ioQueue must exist).
    @objc func setupCoprocessSources(readFd: Int32, writeFd: Int32) {
        guard readFd >= 0, writeFd >= 0 else { return }

        // Tear down any existing coprocess sources before creating new ones.
        teardownCoprocessSources()

        // Read source — reads coprocess stdout, feeds data back as PTY input
        let crs = DispatchSource.makeReadSource(fileDescriptor: readFd, queue: ioQueue)
        crs.setEventHandler { [weak self] in
            self?.handleCoprocessReadEvent()
        }
        crs.resume()
        crs.suspend()
        coprocessReadSource = crs
        coprocessReadSourceSuspended = true

        // Write source — flushes outputBuffer to coprocess stdin
        let cws = DispatchSource.makeWriteSource(fileDescriptor: writeFd, queue: ioQueue)
        cws.setEventHandler { [weak self] in
            self?.handleCoprocessWriteEvent()
        }
        cws.resume()
        cws.suspend()
        coprocessWriteSource = cws
        coprocessWriteSourceSuspended = true

        updateCoprocessReadSourceState()
        updateCoprocessWriteSourceState()
    }

    /// Any queue. Tears down coprocess dispatch sources.
    @objc func teardownCoprocessSources() {
        let crs = coprocessReadSource
        let cws = coprocessWriteSource

        coprocessReadSource = nil
        coprocessWriteSource = nil

        guard crs != nil || cws != nil else { return }

        if isOnIOQueue {
            cancelSource(crs, suspended: coprocessReadSourceSuspended)
            cancelSource(cws, suspended: coprocessWriteSourceSuspended)
            coprocessReadSourceSuspended = false
            coprocessWriteSourceSuspended = false
        } else {
            var rSuspended = false
            var wSuspended = false
            ioQueue.sync {
                rSuspended = self.coprocessReadSourceSuspended
                wSuspended = self.coprocessWriteSourceSuspended
            }
            ioQueue.sync {
                self.cancelSource(crs, suspended: rSuspended)
                self.cancelSource(cws, suspended: wSuspended)
                self.coprocessReadSourceSuspended = false
                self.coprocessWriteSourceSuspended = false
            }
        }
    }

    /// Any queue. Snapshots coprocess read predicate, dispatches to ioQueue.
    @objc func updateCoprocessReadSourceState() {
        guard let crs = coprocessReadSource else { return }
        let shouldResume = delegate?.ioHandlerShouldResumeCoprocessRead(self) ?? false
        ioQueue.async { [weak self] in
            guard let self else { return }
            if shouldResume && self.coprocessReadSourceSuspended && self.coprocessReadSource != nil {
                crs.resume()
                self.coprocessReadSourceSuspended = false
            } else if !shouldResume && !self.coprocessReadSourceSuspended && self.coprocessReadSource != nil {
                crs.suspend()
                self.coprocessReadSourceSuspended = true
            }
        }
    }

    /// Any queue. Snapshots coprocess write predicate, dispatches to ioQueue.
    @objc func updateCoprocessWriteSourceState() {
        guard let cws = coprocessWriteSource else { return }
        let shouldResume = delegate?.ioHandlerShouldResumeCoprocessWrite(self) ?? false
        ioQueue.async { [weak self] in
            guard let self else { return }
            if shouldResume && self.coprocessWriteSourceSuspended && self.coprocessWriteSource != nil {
                cws.resume()
                self.coprocessWriteSourceSuspended = false
            } else if !shouldResume && !self.coprocessWriteSourceSuspended && self.coprocessWriteSource != nil {
                cws.suspend()
                self.coprocessWriteSourceSuspended = true
            }
        }
    }

    // MARK: - Private Event Handlers (ioQueue)

    /// Read up to 4 * kMaxReadWrite bytes from the PTY fd per event.
    private func handleReadEvent() {
        let iterations = 4
        let bufferSize = kMaxReadWrite * iterations
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var totalBytesRead: Int = 0
        var gotEOF = false

        for _ in 0..<iterations {
            let n = Darwin.read(fd, buffer.advanced(by: totalBytesRead), kMaxReadWrite)
            if n < 0 {
                if errno != EAGAIN && errno != EINTR {
                    delegate?.ioHandlerDidDetectBrokenPipe(self)
                    return
                }
                // EAGAIN/EINTR - stop reading but process what we have
                break
            }
            if n == 0 {
                // EOF - PTY slave side closed (child exited).
                gotEOF = true
                break
            }
            totalBytesRead += n
            if n < kMaxReadWrite {
                // Got less than requested - no more data available
                break
            }
        }

        if totalBytesRead > 0 {
            delegate?.ioHandler(self, didReadData: buffer, length: Int32(totalBytesRead))
            // Re-check state after read (backpressure may have increased)
            updateReadSourceState()
        }

        if gotEOF {
            delegate?.ioHandlerDidDetectBrokenPipe(self)
        }
    }

    /// Write source fired; delegate drains the write buffer.
    private func handleWriteEvent() {
        delegate?.ioHandlerDrainWriteBuffer(self)
        // Re-check state after write (buffer may now be empty)
        updateWriteSourceState()
        // Write buffer shrank — coprocess read source may now be eligible to resume
        updateCoprocessReadSourceState()
    }

    /// Coprocess read source fired; delegate handles the I/O.
    private func handleCoprocessReadEvent() {
        delegate?.ioHandlerHandleCoprocessRead(self)
        updateCoprocessReadSourceState()
    }

    /// Coprocess write source fired; delegate flushes the output buffer.
    private func handleCoprocessWriteEvent() {
        delegate?.ioHandlerHandleCoprocessWrite(self)
        updateCoprocessWriteSourceState()
    }

    // MARK: - Private Helpers

    /// Whether we are currently executing on this handler's ioQueue.
    private var isOnIOQueue: Bool {
        DispatchQueue.getSpecific(key: ioQueueKey) != nil
    }

    /// Resume a suspended source (if needed) then cancel it. GCD requires
    /// suspended sources to be resumed before cancellation.
    private func cancelSource(_ source: DispatchSourceProtocol?, suspended: Bool) {
        guard let source else { return }
        if suspended {
            source.resume()
        }
        source.cancel()
    }
}

// MARK: - Test Accessors

extension PTYTaskIOHandler {
    @objc var testHasReadSource: Bool { readSource != nil }
    @objc var testHasWriteSource: Bool { writeSource != nil }
    @objc var testIsReadSourceSuspended: Bool { readSourceSuspended }
    @objc var testIsWriteSourceSuspended: Bool { writeSourceSuspended }

    @objc var testHasCoprocessReadSource: Bool { coprocessReadSource != nil }
    @objc var testHasCoprocessWriteSource: Bool { coprocessWriteSource != nil }
    @objc var testIsCoprocessReadSourceSuspended: Bool { coprocessReadSourceSuspended }
    @objc var testIsCoprocessWriteSourceSuspended: Bool { coprocessWriteSourceSuspended }

    /// Synchronously wait for the ioQueue to drain all pending work.
    @objc func testWaitForIOQueue() {
        ioQueue.sync {}
    }
}
