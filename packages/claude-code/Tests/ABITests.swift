// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import Darwin

typealias HostCommand = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Double) -> Void
typealias CreateFunction = @convention(c) (UnsafeMutableRawPointer?, HostCommand) -> UnsafeMutableRawPointer?
typealias DestroyFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void
typealias UpdateFunction = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void
typealias EventFunction = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
typealias SnapshotFunction = @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?
typealias SettingsFunction = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
typealias TabFunction = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
typealias ActivityFunction = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
typealias TestProtocolFunction = @convention(c) () -> Int32

private final class HostRecorder {
    var names: [String] = []
    var wrongThread = false
    var destroyed = false
    var lateCallbacks = 0
}

private let receiveCommand: HostCommand = { context, command, _ in
    guard let context, let command else { return }
    let recorder = Unmanaged<HostRecorder>.fromOpaque(context).takeUnretainedValue()
    recorder.wrongThread = recorder.wrongThread || !Thread.isMainThread
    if recorder.destroyed { recorder.lateCallbacks += 1 }
    recorder.names.append(String(cString: command))
}

@main
struct ABITests {
    static var assertions = 0
    static var telemetry: URL!
    static var artifactRoot: URL!

    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        guard try value() else { throw NSError(domain: "ClaudeABITests", code: assertions,
                                               userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func records() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: telemetry), data.count < 5_000_000 else { return [] }
        return data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }
    static func events(_ name: String) -> [[String: Any]] { records().filter { $0["event"] as? String == name } }
    static func last(_ name: String) -> [String: Any]? { events(name).last }

    static func spin(_ duration: TimeInterval) {
        let end = Date().addingTimeInterval(duration)
        while Date() < end { _ = RunLoop.current.run(mode: .default, before: min(end, Date().addingTimeInterval(0.01))) }
    }

    static func wait(_ description: String, timeout: TimeInterval = 15, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { spin(0.02) }
        try expect(condition(), description)
    }

    static func symbol<T>(_ image: UnsafeMutableRawPointer, _ name: String, _: T.Type) throws -> T {
        guard let pointer = dlsym(image, name) else {
            throw NSError(domain: "ClaudeABITests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing ABI export: \(name)"])
        }
        return unsafeBitCast(pointer, to: T.self)
    }

    static func snapshot(_ function: SnapshotFunction, _ instance: UnsafeMutableRawPointer) throws -> [String: Any] {
        guard let pointer = function(instance), strnlen(pointer, 65_537) <= 65_536,
              let data = String(cString: pointer).data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeStorageError.invalidRecord
        }
        return object
    }

    static func send(_ function: EventFunction, _ instance: UnsafeMutableRawPointer, _ name: String) {
        name.withCString { function(instance, $0) }
    }

    static func layout(_ presentation: String, width: Double = 336, height: Double = 132, display: String = "simulated-display-A") -> String {
        "{\"presentation\":\"\(presentation)\",\"displayID\":\"\(display)\",\"unknownFutureField\":true,\"contentSize\":{\"width\":\(width),\"height\":\(height)}}"
    }

    static func mount(_ function: TabFunction, _ instance: UnsafeMutableRawPointer, context: String) throws -> NSViewController {
        let pointer = "sessions".withCString { id in context.withCString { function(instance, id, $0) } }
        guard let pointer else { throw ClaudeStorageError.invalidRecord }
        return Unmanaged<NSViewController>.fromOpaque(pointer).takeRetainedValue()
    }

    static func render(_ controller: NSViewController, size: CGSize, name: String) throws {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentViewController = controller
        controller.view.frame = CGRect(origin: .zero, size: size)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        spin(0.15)
        controller.view.layoutSubtreeIfNeeded()
        try expect(controller.view.bounds.size == size, "\(name) obeys host viewport")
        try expect(controller.preferredContentSize == size, "\(name) reports supplied dimensions")
        guard let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) else {
            throw NSError(domain: "ClaudeABITests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Offscreen bitmap unavailable"])
        }
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ClaudeStorageError.io }
        try png.write(to: artifactRoot.appendingPathComponent(name + ".png"))
        try expect(png.count > 200, "\(name) creates a render artifact")
    }

    static func fixtures(at directory: URL) throws {
        try ClaudeStorage.prepare(directory: directory)
        let now = Date().timeIntervalSince1970
        for index in 0..<1_000 {
            let suffix = String(format: "%04d", index)
            let waiting = index % 5 == 4
            let session = ClaudeSession(id: "probe-\(suffix)", project: "Project \(suffix)",
                directory: "/tmp/boring-claude-synthetic/Project \(suffix)", phase: waiting ? .needsInput : .working,
                createdAt: now, updatedAt: now + Double(index) / 1000, model: "Claude fixture",
                question: waiting ? "Fixture question \(suffix): which environment?" : nil,
                questionOptions: waiting ? ["Staging", "Production"] : [], attentionKind: waiting ? "question" : nil,
                toolName: waiting ? "AskUserQuestion" : nil,
                usage: ClaudeUsage(updatedAt: now, fiveHour: ClaudeQuotaWindow(remainingPercent: Double(index % 100), resetsAt: now + 3600),
                    sevenDay: ClaudeQuotaWindow(remainingPercent: 63, resetsAt: now + 86_400), contextRemaining: 74))
            try JSONEncoder().encode(session).write(to: ClaudeStorage.sessionURL(id: session.id, directory: directory))
        }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "ClaudeABITests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: ABI-tests /absolute/Claude.bnplugin"])
        }
        artifactRoot = FileManager.default.temporaryDirectory.appendingPathComponent("boring-claude-abi-\(UUID().uuidString)")
        try ClaudeStorage.ensureDirectory(artifactRoot)
        let keep = ProcessInfo.processInfo.environment["BN_CLAUDE_KEEP_FIXTURES"] != nil
        defer { if !keep { try? FileManager.default.removeItem(at: artifactRoot) } }
        let directory = artifactRoot.appendingPathComponent("relay")
        telemetry = artifactRoot.appendingPathComponent("telemetry.jsonl")
        try fixtures(at: directory)
        setenv("BN_CLAUDE_TEST_DIRECTORY", directory.path, 1)
        setenv("BN_CLAUDE_TEST_LOG", telemetry.path, 1)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let binary = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Contents/MacOS/ClaudeCode")
        guard let image = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown loader failure"
            throw NSError(domain: "ClaudeABITests", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        // Never create a release instance: release deliberately ignores test-directory overrides.
        let protocolVersion = try symbol(image, "bn_claude_test_protocol_v1", TestProtocolFunction.self)
        try expect(protocolVersion() == 1, "Debug fixture protocol required before instance creation")
        let create = try symbol(image, "bn_extension_create_v1", CreateFunction.self)
        let destroy = try symbol(image, "bn_extension_destroy_v1", DestroyFunction.self)
        let update = try symbol(image, "bn_extension_update_v1", UpdateFunction.self)
        let event = try symbol(image, "bn_extension_event_v1", EventFunction.self)
        let tabs = try symbol(image, "bn_extension_tabs_v1", SnapshotFunction.self)
        let activities = try symbol(image, "bn_extension_activities_v1", SnapshotFunction.self)
        let tab = try symbol(image, "bn_extension_tab_view_v2", TabFunction.self)
        let legacyTab = try symbol(image, "bn_extension_tab_view_v1", TabFunction.self)
        let activity = try symbol(image, "bn_extension_activity_view_v1", ActivityFunction.self)
        let settings = try symbol(image, "bn_extension_settings_v1", SettingsFunction.self)
        let recorder = HostRecorder()
        let context = Unmanaged.passUnretained(recorder).toOpaque()
        guard let instance = create(context, receiveCommand) else { throw ClaudeStorageError.invalidRecord }
        var destroyed = false
        defer { if !destroyed { destroy(instance) } }
        try expect(recorder.names.isEmpty, "No callbacks during create")
        let publishedTabs = try snapshot(tabs, instance)["tabs"] as? [[String: Any]]
        try expect(publishedTabs?.count == 1, "One tab for 1,000 sessions")
        let logoURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Contents/Resources/ClaudeLogo.png")
        let packagedLogo = try Data(contentsOf: logoURL)
        let publishedLogo = (publishedTabs?.first?["iconPNG"] as? String).flatMap { Data(base64Encoded: $0) }
        try expect(publishedLogo == packagedLogo, "Tab publishes the exact bundled Claude logo")
        try expect(last("resources")?["logoExists"] as? Bool == true, "Native UI resolves the logo from its own bundle")
        try expect(last("resources")?["helperExists"] as? Bool == true, "Setup resolves the bundled relay helper")
        try expect(events("controller.create").isEmpty, "Registration creates no eager controllers")
        let started = Date()
        update(instance, nil, 0)
        try wait("All 1,000 fixture sessions loaded") { last("state.loaded")?["sessionCount"] as? Int == 1_000 }
        let loadMilliseconds = Date().timeIntervalSince(started) * 1000
        try expect(events("controller.create").isEmpty, "Loading 1,000 sessions creates zero controllers")
        try expect((snapshot(activities, instance)["activities"] as? [[String: Any]])?.count == 1, "One aggregate activity for 200 questions")
        try expect(last("state.loaded")?["attentionCount"] as? Int == 200, "All waiting sessions counted")
        send(event, instance, "claude.test.search:Project 0999")
        try wait("Search reaches far-end session") { last("state.search")?["visibleCount"] as? Int == 1 }
        send(event, instance, "claude.test.select:probe-0999")
        send(event, instance, "claude.test.search:NoSuchFixture")
        try expect(last("state.search")?["visibleCount"] as? Int == 0, "Empty search result is stable")
        send(event, instance, "claude.test.search:")
        try expect(last("state.search")?["visibleCount"] as? Int == 1_000, "Clearing search restores all sessions")
        send(event, instance, "claude.test.select:probe-0424")

        for invalid in ["{}", layout("unknown"), layout("compact", width: -1), layout("compact", height: 0),
                        "{\"presentation\":\"compact\",\"contentSize\":{\"width\":1e999,\"height\":132}}", String(repeating: "x", count: 65_537)] {
            let pointer = "sessions".withCString { id in invalid.withCString { tab(instance, id, $0) } }
            try expect(pointer == nil, "Malformed/unsupported context is rejected")
        }
        try expect(events("controller.create").isEmpty, "Invalid requests create no controllers")
        let validContext = layout("compact")
        try expect("unknown".withCString { id in validContext.withCString { tab(instance, id, $0) } } == nil, "Unknown tab ID rejected")

        weak var weakRegular: NSViewController?
        weak var weakCompact: NSViewController?
        var heldAfterDestroy: NSViewController?
        try autoreleasepool {
            var regular: NSViewController? = try mount(tab, instance, context: layout("regular", width: 578))
            var compact: NSViewController? = try mount(tab, instance, context: layout("compact"))
            weakRegular = regular; weakCompact = compact
            try expect(regular !== compact, "Every simultaneous mount owns a fresh native controller")
            try render(regular!, size: CGSize(width: 578, height: 132), name: "regular-1000")
            try render(compact!, size: CGSize(width: 336, height: 132), name: "compact-1000")
            let createdBeforeUpdate = events("controller.create").count
            let loads = events("state.loaded").count
            try ClaudeStorage.update(id: "probe-0424", directory: directory) { old in
                guard var value = old else { return nil }
                value.usage?.fiveHour?.remainingPercent = 17
                value.usage?.updatedAt = Date().timeIntervalSince1970
                return value
            }
            send(event, instance, "claude.test.refresh")
            try wait("Live update reaches mounted views") { events("state.loaded").count > loads }
            try expect(events("controller.create").count == createdBeforeUpdate, "Live updates retain existing controllers")
            try expect(last("state.loaded")?["selectedID"] as? String == "probe-0424", "Live update preserves non-default selection")
            try expect(last("state.loaded")?["selectedQuestionPresent"] as? Bool == true, "Usage update preserves waiting question")
            try render(compact!, size: CGSize(width: 336, height: 132), name: "compact-live-update")
            regular = nil; compact = nil
        }
        spin(0.1)
        try expect(weakRegular == nil && weakCompact == nil, "Unmount releases native tab controllers")

        try autoreleasepool {
            for index in 0..<20 {
                let compact = index.isMultiple(of: 2)
                let controller = try mount(tab, instance, context: layout(compact ? "compact" : "regular",
                    width: compact ? 336 : 578, display: "simulated-display-\(index % 2)"))
                _ = controller.view
                try expect(controller.preferredContentSize.width == (compact ? 336 : 578), "Remount uses current presentation bounds")
            }
            let narrow = try mount(tab, instance, context: layout("regular", width: 300, height: 120))
            try render(narrow, size: CGSize(width: 300, height: 120), name: "narrow-regular")
            let legacyPointer = "sessions".withCString { legacyTab(instance, $0, nil) }
            try expect(legacyPointer != nil, "Legacy regular factory remains available")
            if let legacyPointer { _ = Unmanaged<NSViewController>.fromOpaque(legacyPointer).takeRetainedValue().view }
            let first = "attention".withCString { activity(instance, $0, 0, nil) }
            let second = "attention".withCString { activity(instance, $0, 0, nil) }
            try expect(first != nil && second != nil && first != second, "Activity mount is fresh for each display")
            if let first { _ = Unmanaged<NSViewController>.fromOpaque(first).takeRetainedValue().view }
            if let second { _ = Unmanaged<NSViewController>.fromOpaque(second).takeRetainedValue().view }
            try expect("attention".withCString { activity(instance, $0, 2, nil) } == nil, "Invalid activity region rejected")
            let borrowed = settings(instance)
            try expect(borrowed != nil && settings(instance) == borrowed, "Settings follows borrowed stable-controller contract")
            if let borrowed { heldAfterDestroy = Unmanaged<NSViewController>.fromOpaque(borrowed).takeUnretainedValue() }
        }
        spin(0.1)
        let loadsBeforeDestroy = events("state.loaded").count
        let callbacksBeforeDestroy = recorder.names.count
        destroy(instance); destroyed = true; recorder.destroyed = true
        // Pending directory work and externally retained settings must become inert after destruction.
        try ClaudeStorage.update(id: "probe-0424", directory: directory) { old in
            guard var value = old else { return nil }; value.phase = .idle; value.question = nil; return value
        }
        spin(0.4)
        try expect(recorder.names.count == callbacksBeforeDestroy && recorder.lateCallbacks == 0, "No callback after destroy")
        try expect(events("state.loaded").count == loadsBeforeDestroy, "Pending reload cannot publish after destroy")
        try expect(!recorder.wrongThread, "Every host callback is on the main thread")
        autoreleasepool { _ = heldAfterDestroy?.view; heldAfterDestroy = nil }
        spin(0.1)
        let creations = events("controller.create")
        let destructions = events("controller.destroy")
        let createdIDs = Set(creations.compactMap { $0["controller"] as? String })
        let destroyedIDs = Set(destructions.compactMap { $0["controller"] as? String })
        try expect(createdIDs == destroyedIDs, "All controller lifetimes balance")
        try expect(events("instance.create").count == events("instance.destroy").count, "Instance lifetimes balance")
        let report: [String: Any] = ["assertions": assertions, "sessions": 1_000, "waitingSessions": 200,
            "initialLoadMilliseconds": loadMilliseconds, "eagerControllers": 0,
            "controllersCreated": creations.count, "controllersDestroyed": destructions.count,
            "lateCallbacks": recorder.lateCallbacks, "physicalDisplaysTested": false, "artifactDirectory": artifactRoot.path]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifactRoot.appendingPathComponent("abi-report.json"))
        print("ABI tests passed: \(assertions) assertions; 1,000 sessions loaded in \(Int(loadMilliseconds)) ms; zero eager controllers; \(creations.count)/\(destructions.count) controller lifetimes; zero late callbacks.")
        if keep { print("Fixture and render artifacts: \(artifactRoot.path)\nLive UI relay: \(directory.path)") }
        // Swift images remain loaded for process lifetime; dlclose would invalidate runtime metadata.
    }
}
