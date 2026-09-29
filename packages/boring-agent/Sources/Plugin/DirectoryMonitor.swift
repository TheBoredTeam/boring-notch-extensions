// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// One event-driven reader per instance. Atomic relay writes generate a single
/// coalesced reload, irrespective of the number of sessions or visible views.
final class ClaudeDirectoryMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "theboringteam.claude.directory", qos: .utility)
    private let directory: URL
    private let receive: @Sendable (Result<[ClaudeSession], Error>) -> Void
    private let receiveUsage: @Sendable (Result<ClaudeAccountUsageRecord?, Error>) -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var work: DispatchWorkItem?
    private var stopped = false
    private var watchingSessions = false

    init(directory: URL,
         receiveUsage: @escaping @Sendable (Result<ClaudeAccountUsageRecord?, Error>) -> Void,
         receive: @escaping @Sendable (Result<[ClaudeSession], Error>) -> Void) {
        self.directory = directory
        self.receive = receive
        self.receiveUsage = receiveUsage
        queue.async { [self] in
            watch(directory)
            ensureSessionWatch()
            schedule()
        }
    }

    func refresh() {
        queue.async { [self] in
            guard !stopped else { return }
            ensureSessionWatch()
            schedule()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            work?.cancel()
            work = nil
            sources.forEach { $0.cancel() }
            sources.removeAll()
        }
    }

    private func ensureSessionWatch() {
        guard !watchingSessions else { return }
        watchingSessions = watch(directory.appendingPathComponent("sessions", isDirectory: true))
    }

    @discardableResult
    private func watch(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_EVTONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .revoke], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, !self.stopped else { return }
            if let data = source?.data, !data.intersection([.delete, .rename, .revoke]).isEmpty {
                // Rebuild both directory watches after replacement. The read
                // reports revoked access, rather than retaining stale data.
                self.sources.forEach { $0.cancel() }
                self.sources.removeAll()
                self.watchingSessions = false
                self.watch(self.directory)
            }
            self.ensureSessionWatch()
            self.schedule()
        }
        source.setCancelHandler { close(descriptor) }
        sources.append(source)
        source.resume()
        return true
    }

    private func schedule() {
        work?.cancel()
        let next = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.ensureSessionWatch()
            let result = Result { try ClaudeStorage.loadSessions(directory: self.directory) }
            guard !self.stopped else { return }
            self.receive(result)
            let usage = Result { try ClaudeStorage.accountUsage(directory: self.directory) }
            guard !self.stopped else { return }
            self.receiveUsage(usage)
        }
        work = next
        queue.asyncAfter(deadline: .now() + .milliseconds(150), execute: next)
    }
}
