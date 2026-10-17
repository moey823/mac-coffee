import Darwin
import Foundation
import MacCoffeeCore

struct LidAwakeJournalStore {
    private let stateName = "session.json"
    private let temporaryName = ".session.json.tmp"

    func read() throws -> LidAwakeSessionRecord? {
        let directory: Int32
        do {
            directory = try openDirectory(create: false)
        } catch JournalError.missingDirectory {
            return nil
        }
        defer { close(directory) }
        let file = openat(directory, stateName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw failure("open recovery journal")
        }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0 else { throw failure("inspect recovery journal") }
        try validate(fileInfo: info, expectedType: mode_t(S_IFREG), maximumSize: 64 * 1024)
        guard info.st_size > 0 else { throw JournalError.invalidJournal }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("read recovery journal")
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= 64 * 1024 else { throw JournalError.invalidJournal }
        }
        do {
            return try JSONDecoder().decode(LidAwakeSessionRecord.self, from: data)
        } catch {
            throw JournalError.invalidJournal
        }
    }

    func write(_ record: LidAwakeSessionRecord) throws {
        let directory = try openDirectory(create: true)
        defer { close(directory) }
        let data = try JSONEncoder().encode(record)
        _ = unlinkat(directory, temporaryName, 0)
        let file = openat(
            directory,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard file >= 0 else { throw failure("create recovery journal") }
        var keepTemporary = true
        defer {
            close(file)
            if keepTemporary { _ = unlinkat(directory, temporaryName, 0) }
        }
        guard fchmod(file, mode_t(0o600)) == 0, fchown(file, 0, 0) == 0 else {
            throw failure("secure recovery journal")
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw JournalError.invalidJournal }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw failure("write recovery journal")
                }
                guard count > 0 else { throw JournalError.invalidJournal }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw failure("flush recovery journal") }
        guard renameat(directory, temporaryName, directory, stateName) == 0 else {
            throw failure("commit recovery journal")
        }
        keepTemporary = false
        guard fsync(directory) == 0 else { throw failure("flush recovery directory") }
    }

    func remove() throws {
        let directory: Int32
        do {
            directory = try openDirectory(create: false)
        } catch JournalError.missingDirectory {
            return
        }
        defer { close(directory) }
        if unlinkat(directory, stateName, 0) != 0, errno != ENOENT {
            throw failure("remove recovery journal")
        }
        guard fsync(directory) == 0 else { throw failure("flush recovery directory") }
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        let library = open("/Library", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard library >= 0 else { throw failure("open /Library") }
        defer { close(library) }
        try validateDirectory(library)

        let support = openat(library, "Application Support", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard support >= 0 else { throw failure("open Application Support") }
        defer { close(support) }
        try validateDirectory(support)

        let appDirectory = try openOrCreateChild("MacCoffee", under: support, mode: mode_t(0o755), create: create)
        defer { close(appDirectory) }
        return try openOrCreateChild("LidAwake", under: appDirectory, mode: mode_t(0o700), create: create)
    }

    private func openOrCreateChild(_ name: String, under parent: Int32, mode: mode_t, create: Bool) throws -> Int32 {
        var child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if child < 0, errno == ENOENT, create {
            if mkdirat(parent, name, mode) != 0, errno != EEXIST {
                throw failure("create secure state directory")
            }
            child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard child >= 0 else {
            if errno == ENOENT, !create { throw JournalError.missingDirectory }
            throw failure("open secure state directory")
        }
        do { try validateDirectory(child) } catch { close(child); throw error }
        return child
    }

    private func validateDirectory(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure("inspect state directory") }
        try validate(fileInfo: info, expectedType: mode_t(S_IFDIR), maximumSize: 0)
    }

    private func validate(fileInfo info: stat, expectedType: mode_t, maximumSize: off_t) throws {
        guard info.st_uid == 0,
              (info.st_mode & mode_t(S_IFMT)) == expectedType,
              (info.st_mode & mode_t(0o022)) == 0,
              maximumSize == 0 || info.st_size <= maximumSize else {
            throw JournalError.unsafePath
        }
    }

    private func failure(_ operation: String) -> JournalError {
        JournalError.posix(operation, errno)
    }
}

enum JournalError: Error, LocalizedError {
    case unsafePath
    case invalidJournal
    case missingDirectory
    case posix(String, Int32)

    var errorDescription: String? {
        switch self {
        case .unsafePath: "The root-owned recovery journal path is not safe."
        case .invalidJournal: "The root-owned recovery journal is invalid."
        case .missingDirectory: "The recovery journal has not been created yet."
        case .posix(let operation, let code): "Could not \(operation) (POSIX error \(code))."
        }
    }
}
