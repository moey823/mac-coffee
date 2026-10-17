import Darwin
import Foundation

public enum LidAwakeProcessPath {
    public static func executableURL(for processID: Int32) throws -> URL {
        // The SDK defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN; Swift cannot import that macro.
        // proc_pidpath rejects larger buffers with EOVERFLOW.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        errno = 0
        let count = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(processID, bytes.baseAddress, UInt32(bytes.count))
        }
        guard count > 0 else {
            throw LidAwakeProcessPathError.unavailable(processID: processID, systemError: errno)
        }
        return URL(fileURLWithPath: String(cString: buffer))
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }
}

public enum LidAwakeProcessPathError: Error, LocalizedError {
    case unavailable(processID: Int32, systemError: Int32)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let processID, let systemError):
            "Could not resolve process \(processID)'s executable path (POSIX error \(systemError))."
        }
    }
}
