// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

public typealias BNClaudeCommand = @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Double
) -> Void

struct ClaudeTabLayout: Decodable {
    enum Presentation: String, Decodable { case regular, compact }
    struct ContentSize: Decodable {
        let width: CGFloat
        let height: CGFloat
        var valid: Bool { width.isFinite && height.isFinite && width > 0 && height > 0 }
        var size: CGSize { CGSize(width: width, height: height) }
    }
    let presentation: Presentation
    let displayID: String?
    let contentSize: ContentSize
    static let legacy = Self(presentation: .regular, displayID: nil,
                             contentSize: ContentSize(width: 578, height: 132))

    static func decode(_ pointer: UnsafePointer<CChar>) -> Self? {
        let count = strnlen(pointer, 65_537)
        guard count <= 65_536,
              let context = try? JSONDecoder().decode(Self.self, from: Data(bytes: pointer, count: count)),
              context.contentSize.valid else { return nil }
        return context
    }
}

/// A fresh native controller per mount, with an independently retained shared
/// state. No controller is cached per session or reused between displays.
@MainActor
@objc(BNClaudeCodeContentController)
final class ClaudeContentController: NSViewController {
    private let content: NSHostingController<AnyView>
    private let role: String
    private let instanceID = UUID().uuidString

    init<Content: View>(rootView: Content, role: String, size: CGSize) {
        content = NSHostingController(rootView: AnyView(rootView))
        self.role = role
        super.init(nibName: nil, bundle: ClaudePluginResources.bundle)
        preferredContentSize = size
        ClaudeTelemetry.write("controller.create", ["controller": instanceID, "role": role,
            "width": size.width, "height": size.height])
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: CGRect(origin: .zero, size: preferredContentSize))
        view.identifier = NSUserInterfaceItemIdentifier("claude-\(role)")
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        addChild(content)
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.width, .height]
        view.addSubview(content.view)
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        content.view.frame = view.bounds
    }
    deinit {
        ClaudeTelemetry.write("controller.destroy", ["controller": instanceID, "role": role])
    }
}

@MainActor
private final class ClaudePlugin {
    let state = AgentDashboardState()
    private var context: UnsafeMutableRawPointer?
    private var command: BNClaudeCommand?
    private var buffer: UnsafeMutablePointer<CChar>?
    private var settings: NSViewController?
    private var ready = false

    init(context: UnsafeMutableRawPointer?, command: @escaping BNClaudeCommand) {
        self.context = context
        self.command = command
        state.activitiesChanged = { [weak self] in self?.send("activities.changed") }
        ClaudeTelemetry.write("instance.create")
        ClaudeTelemetry.write("resources", ["bundle": ClaudePluginResources.bundle?.bundleURL.path ?? "unresolved",
            "helperExists": ClaudePluginResources.helperURL != nil,
            "logoExists": ClaudePluginResources.logoPNG != nil,
            "setupCommand": ClaudePluginResources.setupCommand ?? "unavailable"])
    }

    func receiveUpdate() {
        guard state.isActive, !ready else { return }
        ready = true
        state.start()
        // The relay supplies all feature data. The host need not send artwork
        // or periodic media snapshots to this extension.
        send("presentation.artwork", value: 0)
        send("presentation.active", value: 0)
    }

    private func send(_ name: String, value: Double = 0) {
        guard ready, state.isActive, let command else { return }
        ClaudeTelemetry.write("callback", ["command": name])
        name.withCString { command(context, $0, value) }
    }

    private func encode(_ value: [String: Any]) -> UnsafePointer<CChar>? {
        guard let data = try? JSONSerialization.data(withJSONObject: value), data.count <= 65_536,
              let json = String(data: data, encoding: .utf8) else { return nil }
        free(buffer)
        buffer = strdup(json)
        return buffer.map { UnsafePointer($0) }
    }

    func activitySnapshot() -> UnsafePointer<CChar>? {
        let activities: [[String: Any]] = state.isActive && state.currentAttentionCount > 0 ? [[
            "id": "attention", "label": "BoringAgent: \(state.currentAttentionCount) sessions need input",
            "relevance": "timeSensitive", "surface": "desktop"
        ]] : []
        return encode(["activities": activities])
    }

    func tabSnapshot() -> UnsafePointer<CChar>? {
        let tab: [String: Any] = [
            "id": "sessions", "title": "Agents", "symbol": "square.stack.3d.up.fill",
            "presentations": ["regular", "compact"]
        ]
        return encode(["tabs": state.isActive ? [tab] : []])
    }

    func activityController(id: String, region: Int32) -> NSViewController? {
        guard state.isActive, state.currentAttentionCount > 0, id == "attention", region == 0 || region == 1 else { return nil }
        return ClaudeContentController(rootView: BoringAgentActivityView(state: state, region: region),
            role: region == 0 ? "activity-leading" : "activity-trailing",
            size: CGSize(width: region == 0 ? 62 : 45, height: 24))
    }

    func tabController(id: String, layout: ClaudeTabLayout) -> NSViewController? {
        guard state.isActive, id == "sessions" else { return nil }
        return ClaudeContentController(rootView: BoringAgentTabView(state: state, layout: layout),
            role: "tab-\(layout.presentation.rawValue)", size: layout.contentSize.size)
    }

    var settingsController: NSViewController {
        if let settings { return settings }
        let controller = ClaudeContentController(rootView: BoringAgentSettingsView(state: state),
            role: "settings", size: CGSize(width: 470, height: 540))
        settings = controller
        return controller
    }

    func event(_ name: String) {
        guard state.isActive else { return }
        switch name {
        case "wake", "session-active": state.refresh()
        default: break
        }
        #if DEBUG
        guard ProcessInfo.processInfo.environment["BN_CLAUDE_TEST_DIRECTORY"] != nil else { return }
        if name == "claude.test.refresh" { state.refresh() }
        if name.hasPrefix("claude.test.search:") { state.query = String(name.dropFirst("claude.test.search:".count)) }
        if name.hasPrefix("claude.test.select:") { state.select("claude:" + String(name.dropFirst("claude.test.select:".count))) }
        if name == "agent.test.section:progress" { state.section = .progress }
        if name == "agent.test.section:usage" { state.section = .usage }
        #endif
    }

    func stop() {
        ready = false
        command = nil
        context = nil
        state.stop()
        settings = nil
        free(buffer)
        buffer = nil
        ClaudeTelemetry.write("instance.destroy")
    }
}

private func claudeString(_ pointer: UnsafePointer<CChar>?, limit: Int = 4096) -> String? {
    guard let pointer else { return nil }
    let count = strnlen(pointer, limit + 1)
    guard count <= limit else { return nil }
    return String(data: Data(bytes: pointer, count: count), encoding: .utf8)
}

#if DEBUG
/// The standalone harness checks this before create. Release binaries must not
/// accidentally resolve a real user's bookmark during an isolated test.
@_cdecl("bn_claude_test_protocol_v1")
public func claudeTestProtocol() -> Int32 { 1 }
#endif

@_cdecl("bn_extension_create_v1")
@MainActor
public func createClaude(_ context: UnsafeMutableRawPointer?, _ command: @escaping BNClaudeCommand) -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread else { return nil }
    return Unmanaged.passRetained(ClaudePlugin(context: context, command: command)).toOpaque()
}

@_cdecl("bn_extension_destroy_v1")
@MainActor
public func destroyClaude(_ instance: UnsafeMutableRawPointer?) {
    guard Thread.isMainThread, let instance else { return }
    Unmanaged<ClaudePlugin>.fromOpaque(instance).takeRetainedValue().stop()
}

@_cdecl("bn_extension_update_v1")
@MainActor
public func updateClaude(_ instance: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int) {
    guard Thread.isMainThread, let instance, count >= 0, count <= 2_000_000,
          count == 0 || bytes != nil else { return }
    // No borrowed input is captured. This extension does not consume media.
    Unmanaged<ClaudePlugin>.fromOpaque(instance).takeUnretainedValue().receiveUpdate()
}

@_cdecl("bn_extension_event_v1")
@MainActor
public func eventClaude(_ instance: UnsafeMutableRawPointer?, _ event: UnsafePointer<CChar>?) {
    guard Thread.isMainThread, let instance, let name = claudeString(event) else { return }
    Unmanaged<ClaudePlugin>.fromOpaque(instance).takeUnretainedValue().event(name)
}

@_cdecl("bn_extension_settings_v1")
@MainActor
public func settingsClaude(_ instance: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread, let instance else { return nil }
    let controller = Unmanaged<ClaudePlugin>.fromOpaque(instance).takeUnretainedValue().settingsController
    // Settings is borrowed; the instance keeps it alive until destroy.
    return Unmanaged.passUnretained(controller).toOpaque()
}

@_cdecl("bn_extension_activities_v1")
@MainActor
public func activitiesClaude(_ instance: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    guard Thread.isMainThread, let instance else { return nil }
    return Unmanaged<ClaudePlugin>.fromOpaque(instance).takeUnretainedValue().activitySnapshot()
}

@_cdecl("bn_extension_activity_view_v1")
@MainActor
public func activityViewClaude(_ instance: UnsafeMutableRawPointer?, _ activityID: UnsafePointer<CChar>?,
                               _ region: Int32, _ displayID: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread, let instance, let id = claudeString(activityID, limit: 100),
          let controller = Unmanaged<ClaudePlugin>.fromOpaque(instance).takeUnretainedValue()
            .activityController(id: id, region: region) else { return nil }
    return Unmanaged.passRetained(controller).toOpaque()
}

@_cdecl("bn_extension_tabs_v1")
@MainActor
public func tabsClaude(_ instance: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    guard Thread.isMainThread, let instance else { return nil }
    return Unmanaged<ClaudePlugin>.fromOpaque(instance).takeUnretainedValue().tabSnapshot()
}

@_cdecl("bn_extension_tab_view_v1")
@MainActor
public func tabViewClaude(_ instance: UnsafeMutableRawPointer?, _ tabID: UnsafePointer<CChar>?,
                          _ displayID: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread, let instance, let id = claudeString(tabID, limit: 100),
          let controller = Unmanaged<ClaudePlugin>.fromOpaque(instance).takeUnretainedValue()
            .tabController(id: id, layout: .legacy) else { return nil }
    return Unmanaged.passRetained(controller).toOpaque()
}

@_cdecl("bn_extension_tab_view_v2")
@MainActor
public func tabViewClaudeV2(_ instance: UnsafeMutableRawPointer?, _ tabID: UnsafePointer<CChar>?,
                            _ context: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread, let instance, let id = claudeString(tabID, limit: 100), let context,
          let layout = ClaudeTabLayout.decode(context),
          let controller = Unmanaged<ClaudePlugin>.fromOpaque(instance).takeUnretainedValue()
            .tabController(id: id, layout: layout) else { return nil }
    return Unmanaged.passRetained(controller).toOpaque()
}
