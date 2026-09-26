import Foundation
import Darwin

/// Streams through the caller's existing session and connection pool. The
/// task delegate intentionally does not implement redirect/authentication:
/// Foundation forwards those callbacks to the original session delegate.
enum ChekinanaBoundedImageDownload {
    enum DownloadError: Error, Equatable { case bodyTooLarge }

    struct FileOperations: Sendable {
        var fileName: @Sendable () -> String = {
            "chekinana-bounded-image-\(UUID().uuidString.lowercased()).tmp"
        }
        var didCreate: @Sendable (URL) throws -> Void = { _ in }
        var write: @Sendable (FileHandle, Data) throws -> Void = {
            try $0.write(contentsOf: $1)
        }
        var close: @Sendable (FileHandle) throws -> Void = { try $0.close() }
        var remove: @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    }

    static func download(
        for request: URLRequest,
        session: URLSession,
        maximumByteCount: Int,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        files: FileOperations = FileOperations(),
        validateResponse: @escaping @Sendable (URLResponse) throws -> Void = { _ in }
    ) async throws -> (URL, URLResponse) {
        try Task.checkCancellation()
        retryPendingCleanup()
        try Task.checkCancellation()
        guard request.url != nil else { throw URLError(.badURL) }
        guard maximumByteCount > 0 else { throw DownloadError.bodyTooLarge }
        // Task-specific delegates are supported for the production ephemeral
        // sessions, but Foundation does not support them on background tasks.
        guard session.configuration.identifier == nil else {
            throw URLError(.unsupportedURL)
        }
        let receiver = Receiver(maximumByteCount: maximumByteCount,
            directory: temporaryDirectory, files: files, validateResponse: validateResponse)
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiver.start(request: request, session: session, continuation: continuation)
            }
        } onCancel: {
            receiver.cancel()
        }
        do {
            try Task.checkCancellation()
            return result
        } catch {
            _ = removeTemporaryFileIfOwned(result.0)
            throw error
        }
    }

    /// Returns whether this component owns the URL, not whether unlink has
    /// succeeded. Failed removals remain pending for bounded later retries.
    @discardableResult
    static func removeTemporaryFileIfOwned(_ url: URL) -> Bool {
        CleanupRegistry.shared.release(url)
    }

    static var pendingCleanupCount: Int { CleanupRegistry.shared.pendingCount }

    static func retryPendingCleanup(limit: Int = 8) {
        CleanupRegistry.shared.retry(limit: limit)
    }

    private struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t

        static func descriptor(_ descriptor: Int32) -> Self? {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { return nil }
            return Self(device: info.st_dev, inode: info.st_ino)
        }

        static func path(_ url: URL) -> (identity: Self?, missing: Bool) {
            var info = stat()
            let result = url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
                guard let path else { return (-1, EINVAL) }
                let status = lstat(path, &info)
                return (status, errno)
            }
            guard result.0 == 0 else { return (nil, result.1 == ENOENT) }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return (nil, false) }
            return (Self(device: info.st_dev, inode: info.st_ino), false)
        }
    }

    /// Process-local ownership records contain only this component's URLs and
    /// inode/device identity. Retries never enumerate tmp or target an active
    /// output. Pending failures stay recorded for the lifetime of the process.
    private final class CleanupRegistry: @unchecked Sendable {
        static let shared = CleanupRegistry()
        private struct Entry {
            let token = UUID()
            let identity: FileIdentity?
            let remove: @Sendable (URL) throws -> Void
            var pending = false
            var busy = false
        }
        private let lock = NSLock()
        private var entries: [URL: Entry] = [:]
        private var pendingOrder: [URL] = []

        var pendingCount: Int {
            lock.lock(); defer { lock.unlock() }
            return entries.values.filter(\.pending).count
        }

        func register(_ url: URL, descriptor: Int32, remove: @escaping @Sendable (URL) throws -> Void) {
            let entry = Entry(identity: FileIdentity.descriptor(descriptor), remove: remove)
            lock.lock(); entries[url] = entry; lock.unlock()
        }

        func release(_ url: URL) -> Bool {
            lock.lock()
            guard entries[url] != nil else { lock.unlock(); return false }
            entries[url]?.pending = true
            lock.unlock()
            attempt(url)
            return true
        }

        func retry(limit: Int) {
            lock.lock()
            let count = min(max(0, limit), pendingOrder.count)
            let urls = Array(pendingOrder.prefix(count))
            pendingOrder.removeFirst(count)
            lock.unlock()
            urls.forEach(attempt)
        }

        private func attempt(_ url: URL) {
            lock.lock()
            guard let entry = entries[url], entry.pending, !entry.busy else { lock.unlock(); return }
            entries[url]?.busy = true
            lock.unlock()

            let current = FileIdentity.path(url)
            var retired = current.missing
            if let expected = entry.identity, let actual = current.identity {
                if expected == actual {
                    try? entry.remove(url)
                    retired = FileIdentity.path(url).missing
                } else {
                    // A replacement at the same name is not this operation's
                    // file. Retire its stale authority without deleting it.
                    retired = true
                }
            }
            lock.lock()
            if entries[url]?.token == entry.token {
                if retired {
                    entries[url] = nil
                    pendingOrder.removeAll { $0 == url }
                } else {
                    entries[url]?.busy = false
                    if !pendingOrder.contains(url) { pendingOrder.append(url) }
                }
            }
            lock.unlock()
        }
    }

    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        typealias Output = (URL, URLResponse)

        private let lock = NSRecursiveLock()
        private let maximumByteCount: Int
        private let directory: URL
        private let files: FileOperations
        private let validateResponse: @Sendable (URLResponse) throws -> Void
        private var continuation: CheckedContinuation<Output, Error>?
        private var task: URLSessionDataTask?
        private var response: URLResponse?
        private var fileURL: URL?
        private var handle: FileHandle?
        private var receivedByteCount = 0
        private var finished = false
        private var terminalError: Error?

        init(maximumByteCount: Int, directory: URL, files: FileOperations,
             validateResponse: @escaping @Sendable (URLResponse) throws -> Void) {
            self.maximumByteCount = maximumByteCount
            self.directory = directory
            self.files = files
            self.validateResponse = validateResponse
        }

        func start(request: URLRequest, session: URLSession,
                   continuation: CheckedContinuation<Output, Error>) {
            lock.lock()
            guard !finished else {
                let error = terminalError ?? CancellationError()
                lock.unlock()
                continuation.resume(throwing: error)
                return
            }
            self.continuation = continuation
            let task = session.dataTask(with: request)
            task.delegate = self
            self.task = task
            lock.unlock()
            task.resume()
        }

        func cancel() { finish(error: CancellationError(), cancelTask: true) }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                completionHandler(.cancel)
                return
            }
            do {
                guard self.response == nil else { throw URLError(.badServerResponse) }
                try validateResponse(response)
                guard !finished else {
                    lock.unlock()
                    completionHandler(.cancel)
                    return
                }
                guard response.expectedContentLength <= Int64(maximumByteCount) else {
                    throw DownloadError.bodyTooLarge
                }
                let name = files.fileName()
                guard !finished else {
                    lock.unlock()
                    completionHandler(.cancel)
                    return
                }
                let prefix = "chekinana-bounded-image-"
                let identifier = name.dropFirst(prefix.count).dropLast(4)
                guard directory.isFileURL, name.hasPrefix(prefix), name.hasSuffix(".tmp"),
                      identifier.count == 36, UUID(uuidString: String(identifier)) != nil,
                      name == URL(fileURLWithPath: name).lastPathComponent else {
                    throw URLError(.cannotCreateFile)
                }
                let url = directory.appendingPathComponent(name)
                let opened = url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
                    guard let path else { return (-1, EINVAL) }
                    let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                        mode_t(S_IRUSR | S_IWUSR))
                    return (descriptor, errno)
                }
                guard opened.0 >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(opened.1)) }
                // No throwing operation lies between atomic exclusive open
                // and recording ownership of its descriptor and exact path.
                fileURL = url
                handle = FileHandle(fileDescriptor: opened.0, closeOnDealloc: true)
                CleanupRegistry.shared.register(url, descriptor: opened.0, remove: files.remove)
                try files.didCreate(url)
                guard !finished else {
                    lock.unlock()
                    completionHandler(.cancel)
                    return
                }
                self.response = response
                lock.unlock()
                completionHandler(.allow)
            } catch {
                lock.unlock()
                finish(error: error, cancelTask: true)
                completionHandler(.cancel)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive data: Data) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            let total = receivedByteCount.addingReportingOverflow(data.count)
            guard !total.overflow, total.partialValue <= maximumByteCount else {
                lock.unlock()
                finish(error: DownloadError.bodyTooLarge, cancelTask: true)
                return
            }
            guard let handle, response != nil else {
                lock.unlock()
                finish(error: URLError(.badServerResponse), cancelTask: true)
                return
            }
            do {
                try files.write(handle, data)
                if !finished { receivedByteCount = total.partialValue }
                lock.unlock()
            } catch {
                lock.unlock()
                finish(error: error, cancelTask: true)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            finish(error: error, cancelTask: false)
        }

        private func finish(error: Error?, cancelTask: Bool) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            terminalError = error
            let continuation = self.continuation
            let task = self.task
            let handle = self.handle
            let url = fileURL
            let response = self.response
            self.continuation = nil
            self.task = nil
            self.handle = nil
            fileURL = nil
            self.response = nil
            lock.unlock()

            if cancelTask { task?.cancel() }
            var failure = error
            if let handle {
                do { try files.close(handle) }
                catch {
                    failure = failure ?? error
                    try? handle.close()
                }
            }
            if failure == nil, let url, let response {
                continuation?.resume(returning: (url, response))
            } else {
                if let url { _ = CleanupRegistry.shared.release(url) }
                continuation?.resume(throwing: failure ?? URLError(.badServerResponse))
            }
        }
    }
}
