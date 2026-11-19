import Foundation

/// A lock the iOS app and its AutoFill extension share: `flock` on a file in the shared folder, released by the system if the process ends. Reentrant
/// within a process. If the file cannot be opened (the device is locked before its first unlock, when nothing in the vault can be read
/// anyway), the work runs without it rather than locking the user out of the vault.
public final class FileLock {
    private let path: String
    private let keepAlive: ((Bool) -> Void)?
    private let mutex = NSRecursiveLock()
    private var depth = 0
    private var descriptor: Int32 = -1
    /// `keepAlive(true)` runs before the lock is taken and `keepAlive(false)` after it is given up.
    public init(path: String, keepAlive: ((Bool) -> Void)? = nil) { self.path = path; self.keepAlive = keepAlive }

    public func run<T>(_ body: () throws -> T) rethrows -> T {
        mutex.lock(); defer { mutex.unlock() }
        if depth == 0 { acquire() }
        depth += 1
        defer { depth -= 1; if depth == 0 { release() } }
        return try body()
    }
    private func acquire() {
        keepAlive?(true)
        descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { close(descriptor); descriptor = -1; return }
        }
    }
    private func release() {
        if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
        keepAlive?(false)
    }
}
