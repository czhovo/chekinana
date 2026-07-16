import Foundation

enum ChekinanaAsyncDeadlineError: LocalizedError, Equatable {
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .timedOut: "photo loading timed out"
        case .cancelled: "photo loading was cancelled"
        }
    }
}

enum ChekinanaAsyncDeadline {
    static func run<Value: Sendable>(
        nanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = ChekinanaAsyncRace<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                let operationTask = Task {
                    do {
                        race.resolve(.success(try await operation()))
                    } catch is CancellationError {
                        race.resolve(.failure(ChekinanaAsyncDeadlineError.cancelled))
                    } catch {
                        race.resolve(.failure(error))
                    }
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                        race.resolve(.failure(ChekinanaAsyncDeadlineError.timedOut))
                    } catch {
                        // The winning branch cancels this task.
                    }
                }
                race.setTasks(operation: operationTask, timeout: timeoutTask)
            }
        } onCancel: {
            race.resolve(.failure(ChekinanaAsyncDeadlineError.cancelled))
        }
    }
}

private final class ChekinanaAsyncRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var result: Result<Value, Error>?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setTasks(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
        lock.lock()
        if result != nil {
            lock.unlock()
            operation.cancel()
            timeout.cancel()
            return
        }
        operationTask = operation
        timeoutTask = timeout
        lock.unlock()
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        let operationTask = operationTask
        let timeoutTask = timeoutTask
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}

struct ChekinanaAlbumPickerStateMachine: Equatable {
    enum Phase: Equatable {
        case presenting
        case awaitingSelection
        case processing
        case completed
        case cancelled
        case failed
    }

    struct Session: Equatable {
        let id: UUID
        var phase: Phase
    }

    struct TerminalSession: Equatable {
        let id: UUID
        let phase: Phase
    }

    private(set) var activeSession: Session?
    private(set) var lastTerminalSession: TerminalSession?

    var activeSessionID: UUID? {
        activeSession?.id
    }

    var isPresented: Bool {
        activeSession?.phase == .presenting
    }

    @discardableResult
    mutating func begin(id: UUID = UUID()) -> UUID {
        if let activeSession {
            lastTerminalSession = TerminalSession(id: activeSession.id, phase: .cancelled)
        }
        activeSession = Session(id: id, phase: .presenting)
        return id
    }

    @discardableResult
    mutating func markAwaitingSelection(sessionID: UUID) -> Bool {
        guard let session = activeSession, session.id == sessionID else { return false }
        if session.phase == .awaitingSelection {
            return true
        }
        guard session.phase == .presenting else { return false }
        activeSession?.phase = .awaitingSelection
        return true
    }

    @discardableResult
    mutating func beginProcessing(sessionID: UUID) -> Bool {
        guard let session = activeSession,
              session.id == sessionID,
              session.phase == .presenting || session.phase == .awaitingSelection else {
            return false
        }

        activeSession?.phase = .processing
        return true
    }

    @discardableResult
    mutating func cancel(sessionID: UUID) -> Bool {
        guard let session = activeSession,
              session.id == sessionID,
              session.phase == .presenting || session.phase == .awaitingSelection else {
            return false
        }

        finish(sessionID: sessionID, phase: .cancelled)
        return true
    }

    @discardableResult
    mutating func cancelProcessing(sessionID: UUID) -> Bool {
        guard activeSession == Session(id: sessionID, phase: .processing) else { return false }
        finish(sessionID: sessionID, phase: .cancelled)
        return true
    }

    @discardableResult
    mutating func complete(sessionID: UUID) -> Bool {
        guard activeSession == Session(id: sessionID, phase: .processing) else { return false }
        finish(sessionID: sessionID, phase: .completed)
        return true
    }

    /// Runs a synchronous, MainActor-owned commit only while `sessionID` is
    /// still the current processing session. The state check, mutation, and
    /// terminal transition deliberately contain no suspension point, so a
    /// replacement picker session cannot interleave with ledger registration.
    mutating func finalize<Result>(
        sessionID: UUID,
        operation: () throws -> Result
    ) throws -> Result? {
        guard activeSession == Session(id: sessionID, phase: .processing) else { return nil }

        do {
            let result = try operation()
            finish(sessionID: sessionID, phase: .completed)
            return result
        } catch {
            finish(sessionID: sessionID, phase: .failed)
            throw error
        }
    }

    @discardableResult
    mutating func failProcessing(sessionID: UUID) -> Bool {
        guard activeSession == Session(id: sessionID, phase: .processing) else { return false }
        finish(sessionID: sessionID, phase: .failed)
        return true
    }

    private mutating func finish(sessionID: UUID, phase: Phase) {
        lastTerminalSession = TerminalSession(id: sessionID, phase: phase)
        activeSession = nil
    }
}
