// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

final class ClaudeFocusBroker {
    let directory: URL
    let allowUI: Bool
    private var watcher: DispatchSourceFileSystemObject?
    private var lease: Int32 = -1

    init(directory: URL, allowUI: Bool = true) { self.directory = directory; self.allowUI = allowUI }

    func start() throws {
        try ClaudeStorage.prepare(directory: directory)
        lease = open(directory.appendingPathComponent(".broker.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lease >= 0, flock(lease, LOCK_EX | LOCK_NB) == 0 else { throw ClaudeStorageError.io }
        let descriptor = open(directory.appendingPathComponent("requests").path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ClaudeStorageError.io }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.processPending() }
        source.setCancelHandler { close(descriptor) }
        watcher = source
        source.resume()
        processPending()
    }

    func processPending() {
        let folder = directory.appendingPathComponent("requests")
        guard (try? ClaudeStorage.checkDirectory(folder)) != nil,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for url in files.prefix(128) where url.pathExtension == "json" {
            defer { try? FileManager.default.removeItem(at: url) }
            guard let bytes = try? ClaudeStorage.read(url, limit: 2048),
                  let request = try? JSONDecoder().decode(ClaudeFocusRequest.self, from: bytes),
                  request.schemaVersion == 1, ClaudeValidation.identifier(request.id),
                  url.deletingPathExtension().lastPathComponent == request.id,
                  request.createdAt.isFinite,
                  abs(Date().timeIntervalSince1970 - request.createdAt) < 120,
                  let session = try? ClaudeStorage.session(id: request.sessionID, directory: directory) else { continue }
            let receipt = ClaudeOriginResolver.focus(session, allowUI: allowUI)
            if let encoded = try? JSONEncoder().encode(receipt) {
                try? ClaudeStorage.atomicWrite(encoded, to: directory.appendingPathComponent("receipts/\(session.id).json"))
            }
        }
    }

    deinit { watcher?.cancel(); if lease >= 0 { flock(lease, LOCK_UN); close(lease) } }
}
