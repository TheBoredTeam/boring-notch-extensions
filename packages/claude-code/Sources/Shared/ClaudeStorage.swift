// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

enum ClaudeStorageError: Error, LocalizedError {
    case invalidRecord, unsafePath, tooLarge, full, io
    var errorDescription: String? {
        switch self {
        case .invalidRecord: return "The relay record is invalid."
        case .unsafePath: return "The relay folder contains an unsafe path or is not owned by this user."
        case .tooLarge: return "The relay input exceeds its size limit."
        case .full: return "The relay has reached its session or request limit."
        case .io: return "The relay could not read or save its private data."
        }
    }
}

enum ClaudeStorage {
    static let maximumSessions = 2_000
    static let maximumRecordBytes = 65_536
    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/BoringClaude", isDirectory: true)

    static func prepare(directory: URL) throws {
        try ensureDirectory(directory)
        for name in ["sessions", "requests", "receipts"] { try ensureDirectory(directory.appendingPathComponent(name)) }
    }

    static func ensureDirectory(_ directory: URL) throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else { throw ClaudeStorageError.unsafePath }
    }

    static func checkDirectory(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o022) == 0 else { throw ClaudeStorageError.unsafePath }
    }

    static func read(_ url: URL, limit: Int = maximumRecordBytes) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ClaudeStorageError.io }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { throw ClaudeStorageError.unsafePath }
        guard info.st_size >= 0, info.st_size <= limit else { throw ClaudeStorageError.tooLarge }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(limit + 1, 16_384))
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 { if errno == EINTR { continue }; throw ClaudeStorageError.io }
            guard result.count + count <= limit else { throw ClaudeStorageError.tooLarge }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    static func atomicWrite(_ data: Data, to url: URL, limit: Int = maximumRecordBytes) throws {
        guard data.count <= limit else { throw ClaudeStorageError.tooLarge }
        try checkDirectory(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ClaudeStorageError.io }
        defer { close(descriptor); unlink(temporary.path) }
        try data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: written), raw.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ClaudeStorageError.io }
                written += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else { throw ClaudeStorageError.io }
    }

    static func locked<T>(at url: URL, _ operation: () throws -> T) throws -> T {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ClaudeStorageError.io }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { throw ClaudeStorageError.unsafePath }
        while flock(descriptor, LOCK_EX) != 0 { if errno != EINTR { throw ClaudeStorageError.io } }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    static func sessionURL(id: String, directory: URL) throws -> URL {
        guard ClaudeValidation.identifier(id) else { throw ClaudeStorageError.invalidRecord }
        return directory.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(id + ".json")
    }

    static func session(id: String, directory: URL) throws -> ClaudeSession? {
        try checkDirectory(directory)
        try checkDirectory(directory.appendingPathComponent("sessions"))
        let url = try sessionURL(id: id, directory: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let result = try JSONDecoder().decode(ClaudeSession.self, from: read(url))
        guard ClaudeValidation.valid(result), result.id == id else { throw ClaudeStorageError.invalidRecord }
        return result
    }

    static func loadSessions(directory: URL) throws -> [ClaudeSession] {
        try checkDirectory(directory)
        let folder = directory.appendingPathComponent("sessions", isDirectory: true)
        try checkDirectory(folder)
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { throw ClaudeStorageError.io }
        var result: [ClaudeSession] = []
        var examined = 0
        for case let url as URL in enumerator {
            examined += 1
            if examined > maximumSessions { break }
            guard url.pathExtension == "json", let data = try? read(url),
                  let value = try? JSONDecoder().decode(ClaudeSession.self, from: data),
                  ClaudeValidation.valid(value), url.deletingPathExtension().lastPathComponent == value.id else { continue }
            result.append(value)
        }
        return result.sorted {
            if ($0.phase == .needsInput) != ($1.phase == .needsInput) { return $0.phase == .needsInput }
            return $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
    }

    static func update(id: String, directory: URL, transform: (ClaudeSession?) throws -> ClaudeSession?) throws {
        try prepare(directory: directory)
        try locked(at: directory.appendingPathComponent(".store.lock")) {
            let old = try session(id: id, directory: directory)
            guard let value = try transform(old) else { return }
            guard value.id == id, ClaudeValidation.valid(value) else { throw ClaudeStorageError.invalidRecord }
            if old == nil {
                let folder = directory.appendingPathComponent("sessions")
                let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }
                if files.count >= maximumSessions {
                    // Bound history without imposing a lifetime quota on new Claude sessions.
                    // Active and waiting sessions are never evicted to make room.
                    let ended = try loadSessions(directory: directory).filter { $0.phase == .ended }.min { $0.updatedAt < $1.updatedAt }
                    guard let ended else { throw ClaudeStorageError.full }
                    try FileManager.default.removeItem(at: sessionURL(id: ended.id, directory: directory))
                    let receipt = directory.appendingPathComponent("receipts/\(ended.id).json")
                    if FileManager.default.fileExists(atPath: receipt.path) { try FileManager.default.removeItem(at: receipt) }
                }
            }
            try atomicWrite(JSONEncoder().encode(value), to: sessionURL(id: id, directory: directory))
        }
    }

    static func requestFocus(sessionID: String, directory: URL) throws {
        guard try session(id: sessionID, directory: directory) != nil else { throw ClaudeStorageError.invalidRecord }
        let requests = directory.appendingPathComponent("requests")
        try checkDirectory(requests)
        try locked(at: directory.appendingPathComponent(".focus.lock")) {
            let count = try FileManager.default.contentsOfDirectory(atPath: requests.path).count
            guard count < 128 else { throw ClaudeStorageError.full }
            let request = ClaudeFocusRequest(id: UUID().uuidString, sessionID: sessionID, createdAt: Date().timeIntervalSince1970)
            try atomicWrite(JSONEncoder().encode(request), to: requests.appendingPathComponent(request.id + ".json"))
        }
    }

    static func focusReceipt(sessionID: String, directory: URL) throws -> ClaudeFocusReceipt? {
        guard ClaudeValidation.identifier(sessionID) else { throw ClaudeStorageError.invalidRecord }
        let folder = directory.appendingPathComponent("receipts")
        try checkDirectory(folder)
        let url = folder.appendingPathComponent(sessionID + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(ClaudeFocusReceipt.self, from: read(url))
        guard value.schemaVersion == 1, value.sessionID == sessionID, value.updatedAt.isFinite,
              value.message.utf8.count <= 512, ["focused", "appOpened", "unavailable"].contains(value.status)
        else { throw ClaudeStorageError.invalidRecord }
        return value
    }
}
