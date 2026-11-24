import Darwin
import Foundation

/// 不同构建目录的开发包共享同一把进程锁；进程退出后系统自动释放。
final class DevelopmentInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// nil 表示已有开发版持锁；其他系统错误明确抛出，不启动未受保护的实例。
    static func acquire(at url: URL) throws -> DevelopmentInstanceLock? {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(descriptor)
            if error == EWOULDBLOCK { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }
        return DevelopmentInstanceLock(descriptor: descriptor)
    }
}
