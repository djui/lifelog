import Foundation
import Darwin

/// Exclusive, non-blocking `flock` on a file in the output folder, shared by every command that writes there.
public final class ArchiveLock {
    public static let name = ".icloud-exporter.lock"
    private var fd: Int32

    /// `owner` names the command in errors, e.g. "Another export is using this output directory."
    public init(_ url: URL, owner: String) throws {
        fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ExportError.message("Cannot open \(owner) lock.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); fd = -1
            throw ExportError.message("Another \(owner) is using this output directory.")
        }
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        Darwin.close(fd)
        fd = -1
    }

    deinit { release() }
}
