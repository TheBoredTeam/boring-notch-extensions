// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

private let agentAccent = Color(red: 0.90, green: 0.57, blue: 0.42)

private func sessionCount(_ count: Int) -> String {
    "\(count) \(count == 1 ? "session" : "sessions")"
}

private func providerColor(_ provider: AgentProviderSnapshot) -> Color {
    let color = provider.descriptor.accentRGB
    return Color(red: color.red, green: color.green, blue: color.blue)
}

/// Usage may have an independent account connection. A healthy session relay
/// must not conceal an account failure, or make account access look authorized.
private func usageConnection(for provider: AgentProviderSnapshot) -> AgentConnection {
    provider.usageConnection ?? provider.connection
}

private func canRefreshUsage(_ provider: AgentProviderSnapshot) -> Bool {
    switch usageConnection(for: provider) {
    case .connected, .failed: return true
    case .disconnected: return provider.usageConnection == nil
    case .unavailable: return false
    }
}

/// Resource images are template glyphs. Installed application icons retain
/// their original colors. Neither case uses a fabricated provider mark.
@MainActor
private enum AgentLogoCache {
    struct Asset { let image: NSImage; let template: Bool }
    private static var images: [String: Asset] = [:]
    private static var unavailable: Set<String> = []

    static func asset(for provider: AgentProviderSnapshot) -> Asset? {
        let descriptor = provider.descriptor
        let key = "\(descriptor.logoResource ?? "")|\(descriptor.applicationBundleID ?? "")"
        if let asset = images[key] { return asset }
        if unavailable.contains(key) { return nil }
        if images.count + unavailable.count >= 64 {
            images.removeAll(keepingCapacity: true)
            unavailable.removeAll(keepingCapacity: true)
        }
        if let resource = descriptor.logoResource {
            let url = ClaudePluginResources.bundle?.url(forResource: resource, withExtension: nil)
                ?? ClaudePluginResources.bundle?.url(forResource: resource, withExtension: "png")
            if let url, let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                let asset = Asset(image: image, template: true)
                images[key] = asset
                return asset
            }
        }
        if let id = descriptor.applicationBundleID,
           let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let asset = Asset(image: NSWorkspace.shared.icon(forFile: application.path), template: false)
            images[key] = asset
            return asset
        }
        unavailable.insert(key)
        return nil
    }
}

@MainActor
private struct AgentProviderLogo: View {
    let provider: AgentProviderSnapshot
    var size: CGFloat = 24
    var body: some View {
        Group {
            if let asset = AgentLogoCache.asset(for: provider) {
                Image(nsImage: asset.image)
                    .renderingMode(asset.template ? .template : .original)
                    .resizable().scaledToFit()
                    .foregroundStyle(providerColor(provider))
            } else {
                Image(systemName: provider.descriptor.symbol)
                    .font(.system(size: size * 0.72, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
struct BoringAgentTabView: View {
    @ObservedObject var state: AgentDashboardState
    let layout: ClaudeTabLayout
    private var compact: Bool { layout.presentation == .compact || layout.contentSize.width < 440 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 6) {
            header
            if state.section == .usage {
                usage
            } else {
                AgentProgressView(state: state, compact: compact, width: layout.contentSize.width)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black)
        .foregroundStyle(.white)
        .tint(agentAccent)
        .preferredColorScheme(.dark)
        .disabled(!state.isActive)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("boring-agent-dashboard")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: state.section == .usage ? "gauge.with.dots.needle.50percent" : "list.bullet.rectangle")
                .font(.system(size: compact ? 11 : 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(state.section == .usage ? "Usage" : "Progress")
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                sectionButton("Progress", section: .progress)
                sectionButton("Usage", section: .usage)
            }
            .padding(3)
            .background(.white.opacity(0.08), in: Capsule())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Dashboard view")
        }
        .frame(height: compact ? 23 : 24)
    }

    private func sectionButton(_ title: String, section: AgentDashboardSection) -> some View {
        Button { state.section = section } label: {
            Text(title)
                .font(.system(size: compact ? 10 : 11, weight: state.section == section ? .semibold : .medium))
                .foregroundStyle(state.section == section ? .white : .white.opacity(0.50))
                .padding(.horizontal, compact ? 10 : 12).padding(.vertical, 3)
                .background(state.section == section ? .white.opacity(0.13) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(state.section == section ? .isSelected : [])
        .accessibilityIdentifier("boring-agent-section-\(title.lowercased())")
    }

    private var usage: some View {
        GeometryReader { geometry in
            let columns = max(1, min(3, state.providers.count))
            let spacing: CGFloat = compact ? 8 : 12
            let ideal = max(0, geometry.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let cardWidth = max(compact ? 88 : 132, ideal)
            ScrollView(.horizontal) {
                LazyHStack(spacing: spacing) {
                    ForEach(state.providers) { provider in
                        AgentProviderCard(state: state, providerID: provider.id, compact: compact)
                            .frame(width: cardWidth, height: max(0, geometry.size.height))
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("boring-agent-provider-list")
    }
}

@MainActor
private struct AgentProviderCard: View {
    @ObservedObject var state: AgentDashboardState
    let providerID: String
    let compact: Bool
    @State private var showingDetails = false
    @State private var hovering = false

    var body: some View {
        if let provider = state.provider(forID: providerID) {
            Button { showingDetails = true } label: {
                VStack(spacing: 2) {
                    AgentUsageRing(provider: provider, size: compact ? 46 : 54)
                    Text(provider.descriptor.shortName)
                        .font(.system(size: compact ? 10 : 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.86)).lineLimit(1)
                    Text(footnote(provider))
                        .font(.system(size: compact ? 9 : 10)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.46)).lineLimit(1)
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white.opacity(hovering ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                AgentProviderPopover(state: state, providerID: providerID)
            }
            .accessibilityLabel(accessibilityLabel(provider))
            .accessibilityHint("Show provider usage details")
            .accessibilityIdentifier("boring-agent-provider-\(providerID)")
        }
    }

    private func footnote(_ provider: AgentProviderSnapshot) -> String {
        let connection = usageConnection(for: provider)
        if case .failed = connection { return connection.label }
        if provider.usageConnection != nil {
            if case .disconnected = connection { return "Connect usage" }
            if case .unavailable = connection { return "Unavailable" }
        }
        guard let usage = provider.usage, let remaining = usage.limitingRemainingPercent else { return "Unavailable" }
        return "\(Int(remaining.rounded()))% left" + (usage.isStale(at: state.now) ? " · stale" : "")
    }

    private func accessibilityLabel(_ provider: AgentProviderSnapshot) -> String {
        guard let percent = provider.usage?.limitingRemainingPercent else {
            return "\(provider.descriptor.title), usage unavailable. \(footnote(provider))."
        }
        return "\(provider.descriptor.title), \(Int(percent.rounded())) percent remaining in its lowest overall quota. \(footnote(provider))."
    }
}

@MainActor
private struct AgentUsageRing: View {
    let provider: AgentProviderSnapshot
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.13), lineWidth: 3)
            if let remaining = provider.usage?.limitingRemainingPercent {
                Circle().trim(from: 0, to: min(1, max(0, remaining / 100)))
                    .stroke(providerColor(provider), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: remaining)
            }
            AgentProviderLogo(provider: provider, size: size * 0.46)
        }
        .padding(2)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
private struct AgentProviderPopover: View {
    @ObservedObject var state: AgentDashboardState
    let providerID: String

    var body: some View {
        Group {
            if let provider = state.provider(forID: providerID) {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 9) {
                        AgentProviderLogo(provider: provider, size: 25)
                        Text(provider.descriptor.title).font(.system(size: 15, weight: .semibold))
                        if let plan = provider.usage?.planName, !plan.isEmpty {
                            Text(plan).font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.white.opacity(0.09), in: Capsule())
                                .lineLimit(1)
                        }
                        Spacer(minLength: 2)
                        if canRefreshUsage(provider) {
                            Button { state.refreshUsage(providerID: providerID) } label: {
                                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .disabled(provider.usageIsRefreshing)
                            .help(provider.usageIsRefreshing ? "Refreshing usage…" : "Refresh \(provider.descriptor.title)")
                            .accessibilityLabel(provider.usageIsRefreshing ? "Refreshing \(provider.descriptor.title) usage" : "Refresh \(provider.descriptor.title) usage")
                            .accessibilityIdentifier("boring-agent-refresh-\(providerID)")
                        }
                        if provider.usageConnection?.isConnected == true {
                            Menu {
                                Button("Disconnect usage") { state.disconnectUsage(providerID: providerID) }
                            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 12)) }
                            .menuStyle(.borderlessButton).fixedSize().frame(width: 18)
                            .accessibilityLabel("\(provider.descriptor.title) account options")
                        }
                    }
                    if let usage = provider.usage, !usage.windows.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 15) {
                                ForEach(usage.windows) { window in
                                    AgentQuotaRow(window: window, now: state.now, color: providerColor(provider))
                                }
                            }
                        }
                        .frame(height: min(260, CGFloat(usage.windows.count) * 66 - 15))
                        Text((usage.isStale(at: state.now) ? "Stale snapshot. " : "") + "Bars show used allowance; ring shows the lowest overall allowance remaining.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Usage unavailable").font(.system(size: 13, weight: .medium))
                            if usageConnection(for: provider).message == nil {
                                Text(provider.usageConnection != nil && !usageConnection(for: provider).isConnected
                                     ? "Connect account usage to see your plan limits."
                                     : "\(provider.descriptor.title) has not supplied subscription usage.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    // Keep the account source's error alongside its cached
                    // report. Session command feedback never belongs here.
                    if let message = usageConnection(for: provider).message {
                        Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("boring-agent-connection-message-\(providerID)")
                    }
                    if provider.usageConnection != nil {
                        AgentAccountUsageControls(state: state, providerID: providerID)
                    } else if provider.connection.canConfigure && !provider.connection.isConnected {
                        HStack(spacing: 8) {
                            Button("Connect relay folder…") {
                                state.connectProvider(providerID)
                            }
                            if provider.setupCommand != nil {
                                Button("Copy setup") { state.copySetupCommand(providerID: providerID) }
                            }
                        }.controlSize(.small)
                    }
                }
                .tint(providerColor(provider))
            } else {
                Text("Provider unavailable").font(.callout)
            }
        }
        .padding(17).frame(width: 320)
        .preferredColorScheme(.dark)
        .disabled(!state.isActive)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("boring-agent-provider-details-\(providerID)")
    }
}

/// This block is present only for adapters that explicitly expose an account
/// source. Placeholder providers never gain a nonfunctional Connect button.
@MainActor
private struct AgentAccountUsageControls: View {
    @ObservedObject var state: AgentDashboardState
    let providerID: String
    var showsConnectedControls = false

    var body: some View {
        if let provider = state.provider(forID: providerID), let connection = provider.usageConnection {
            VStack(alignment: .leading, spacing: 9) {
                if connection.canConfigure && !connection.isConnected {
                    Text(providerID == "claude"
                         ? "Uses your existing Claude Code sign-in in macOS Keychain to fetch plan limits from Anthropic. BoringAgent never writes Claude credentials."
                         : "Connect account usage to retrieve plan limits from \(provider.descriptor.title).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("boring-agent-usage-consent-\(providerID)")
                    HStack(spacing: 8) {
                        Button(retryLabel(connection)) { state.connectUsage(providerID: providerID) }
                            .buttonStyle(.borderedProminent)
                            .disabled(provider.usageIsRefreshing)
                            .accessibilityIdentifier("boring-agent-connect-usage-\(providerID)")
                        if case .failed = connection {
                            Button("Disconnect usage") { state.disconnectUsage(providerID: providerID) }
                        }
                    }
                    .controlSize(.small)
                } else if connection.isConnected && showsConnectedControls {
                    HStack(spacing: 8) {
                        Button(provider.usageIsRefreshing ? "Refreshing…" : "Refresh usage") {
                            state.refreshUsage(providerID: providerID)
                        }
                        .disabled(provider.usageIsRefreshing)
                        Button("Disconnect usage") { state.disconnectUsage(providerID: providerID) }
                    }
                    .controlSize(.small)
                } else if case .unavailable = connection,
                          provider.setupCommand != nil, provider.connection.canConfigure {
                    Button("Copy relay setup") { state.copySetupCommand(providerID: providerID) }
                        .controlSize(.small)
                        .help("Run the copied command in Terminal to update the relay.")
                }
            }
        }
    }

    private func retryLabel(_ connection: AgentConnection) -> String {
        if case .failed = connection { return "Retry connection" }
        return "Connect usage"
    }
}

private struct AgentQuotaRow: View {
    let window: AgentQuotaWindow
    let now: Date
    let color: Color
    private var usedPercent: Double { 100 - window.remainingPercent }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(window.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text(resetDescription).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 5)
                Text("\(Int(usedPercent.rounded()))% used")
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            AgentThinProgress(value: usedPercent, color: color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title), \(Int(usedPercent.rounded())) percent used. \(resetDescription)")
        .accessibilityIdentifier("boring-agent-quota-\(window.id)")
    }

    private var resetDescription: String {
        guard let reset = window.resetsAt else { return "Reset time unavailable" }
        let remaining = reset - now.timeIntervalSince1970
        guard remaining > 0 else { return "Reset pending a provider update" }
        guard remaining.isFinite, remaining / 60 < Double(Int.max / 2) else { return "Reset time unavailable" }
        let minutes = max(1, Int(remaining / 60))
        if minutes < 60 { return "Resets in \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "Resets in \(hours)h \(minutes % 60)m" }
        return "Resets in \(hours / 24)d \(hours % 24)h"
    }
}

private struct AgentThinProgress: View {
    let value: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.11))
                Capsule().fill(color)
                    .frame(width: geometry.size.width * min(1, max(0, value / 100)))
            }
        }.frame(height: 3).accessibilityHidden(true)
    }
}

@MainActor
private struct AgentProgressView: View {
    @ObservedObject var state: AgentDashboardState
    let compact: Bool
    let width: CGFloat

    var body: some View {
        Group {
            if compact {
                if state.compactSearch {
                    VStack(spacing: 4) {
                        HStack(spacing: 7) {
                            AgentSearchField(state: state)
                            Button { state.compactSearch = false } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .accessibilityLabel("Close session search")
                        }
                        listHeader
                        sessionList
                    }
                } else if let session = state.selectedSession {
                    AgentSessionDetail(state: state, sessionID: session.id, compact: true)
                } else {
                    empty
                }
            } else {
                HStack(alignment: .top, spacing: 11) {
                    VStack(spacing: 3) {
                        AgentSearchField(state: state)
                        listHeader
                        sessionList
                    }
                    .frame(width: max(155, min(205, width * 0.35)))
                    Rectangle().fill(.white.opacity(0.10)).frame(width: 1)
                    if let session = state.selectedSession {
                        AgentSessionDetail(state: state, sessionID: session.id, compact: false)
                    } else {
                        empty
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("boring-agent-progress")
    }

    private var listHeader: some View {
        HStack(spacing: 4) {
            Text(sessionCount(state.visibleSessions.count)).font(.system(size: 8)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button { state.waitingOnly.toggle() } label: {
                Text("Waiting \(state.attentionCount)").font(.system(size: 8, weight: .medium))
                    .foregroundStyle(state.waitingOnly ? agentAccent : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.waitingOnly ? "Show all sessions" : "Show waiting sessions")
            .accessibilityIdentifier("boring-agent-waiting-filter")
        }
    }

    private var sessionList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(state.visibleSessions) { session in
                        Button {
                            state.select(session.id)
                            if compact { state.compactSearch = false }
                        } label: {
                            HStack(spacing: 5) {
                                Circle().fill(state.isStale(session) ? .gray : session.phase == .needsInput ? agentAccent : session.phase == .working ? .green : .gray)
                                    .frame(width: 4, height: 4)
                                Text(session.project).font(.system(size: 10, weight: state.selectedID == session.id ? .medium : .regular))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 1)
                                if let provider = state.provider(forID: session.providerID) {
                                    AgentProviderLogo(provider: provider, size: 11)
                                }
                            }
                            .padding(.horizontal, 5).padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(state.selectedID == session.id ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain).id(session.id)
                        .accessibilityLabel("\(session.project), \(state.statusLabel(session))")
                        .accessibilityIdentifier("boring-agent-session-\(session.id)")
                    }
                }
            }
            .onAppear { if let id = state.selectedID { proxy.scrollTo(id, anchor: .center) } }
            .onChange(of: state.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(state.sessions.isEmpty ? "Ready for your next session" : "No matching sessions")
                    .font(.system(size: 11, weight: .medium))
                if compact {
                    Spacer(minLength: 2)
                    Button { state.compactSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.plain).accessibilityLabel("Search agent sessions")
                }
            }
            Text(state.sessions.isEmpty ? "Connect a supported provider in Usage to see its activity here." : "Try another project or clear the waiting filter.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if state.sessions.isEmpty {
                Button("View providers") { state.section = .usage }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(agentAccent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

@MainActor
private struct AgentSearchField: View {
    @ObservedObject var state: AgentDashboardState
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(.secondary)
            TextField("Search sessions", text: $state.query)
                .textFieldStyle(.plain).font(.system(size: 10))
                .accessibilityIdentifier("boring-agent-session-search")
            if !state.query.isEmpty {
                Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear session search")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }
}

@MainActor
private struct AgentSessionDetail: View {
    @ObservedObject var state: AgentDashboardState
    let sessionID: String
    let compact: Bool
    @State private var showingQuestion = false

    var body: some View {
        if let session = state.session(forID: sessionID) {
            VStack(alignment: .leading, spacing: 4) {
                header(session)
                if session.phase == .needsInput, let question = session.question {
                    Button { showingQuestion = true } label: {
                        HStack(alignment: .top, spacing: 4) {
                            Text(question).font(.system(size: 10, weight: .medium))
                                .lineLimit(2).multilineTextAlignment(.leading)
                            Image(systemName: "ellipsis.bubble").font(.system(size: 9))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("View the full question and choices")
                    .accessibilityIdentifier("boring-agent-question")
                    .popover(isPresented: $showingQuestion, arrowEdge: .bottom) {
                        AgentQuestionPopover(state: state, sessionID: sessionID)
                    }
                } else {
                    Text(state.statusDescription(session)).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).help(state.statusDescription(session))
                }
                Spacer(minLength: 0)
                footer(session)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(session.id)
        }
    }

    private func header(_ session: AgentSession) -> some View {
        HStack(spacing: 5) {
            if let provider = state.provider(forID: session.providerID) {
                AgentProviderLogo(provider: provider, size: 12)
            }
            Text(session.project).font(.system(size: 11, weight: .semibold))
                .lineLimit(1).truncationMode(.middle).help(session.directory)
            Spacer(minLength: 2)
            if state.isStale(session) {
                Text("Stale").font(.system(size: 8)).foregroundStyle(.secondary)
            }
            if compact {
                Button { state.compactSearch = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "magnifyingglass")
                        Text("\(state.visibleSessions.count)").monospacedDigit()
                    }.font(.system(size: 9))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Search \(sessionCount(state.visibleSessions.count))")
                .accessibilityIdentifier("boring-agent-open-search")
            } else if let model = session.model {
                Text(model).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func footer(_ session: AgentSession) -> some View {
        HStack(spacing: 5) {
            Button { state.openSession(session) } label: {
                Label(session.phase == .needsInput ? "Reply in session" : "Open session", systemImage: "arrow.up.right")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.borderedProminent).controlSize(.mini)
            .accessibilityIdentifier("boring-agent-open-session")
            Menu {
                Button("Open original app") { state.openOriginApp(session) }
                Button("Copy resume command") { state.copyResumeCommand(session) }
                Button("Refresh provider") { state.refresh(providerID: session.providerID) }
                if session.phase == .needsInput { Button("View question and choices") { showingQuestion = true } }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 11)) }
            .menuStyle(.borderlessButton).fixedSize().frame(width: 17)
            .accessibilityLabel("Session actions")
            Spacer(minLength: 1)
            if let message = state.actionMessage {
                Text(message).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1).help(message)
            } else if let remaining = session.contextRemaining {
                Text("Context \(Int(remaining.rounded()))%")
                    .font(.system(size: 8)).foregroundStyle(.secondary).monospacedDigit()
                    .help("Session context remaining; this is separate from subscription allowance")
            }
            if compact {
                Button { state.moveSelection(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain).font(.system(size: 8)).accessibilityLabel("Previous session")
                Button { state.moveSelection(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain).font(.system(size: 8)).accessibilityLabel("Next session")
            }
        }
    }
}

@MainActor
private struct AgentQuestionPopover: View {
    @ObservedObject var state: AgentDashboardState
    let sessionID: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let session = state.session(forID: sessionID) {
                HStack(spacing: 7) {
                    if let provider = state.provider(forID: session.providerID) {
                        AgentProviderLogo(provider: provider, size: 18)
                        Text(provider.descriptor.title).font(.headline)
                    }
                    Spacer()
                    Text(session.project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if session.phase == .needsInput, let question = session.question {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 11) {
                            Text(question).font(.callout).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(Array(session.questionOptions.enumerated()), id: \.offset) { index, option in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(option).font(.callout).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 230)
                    Text("Reply or approve in the original session.").font(.caption).foregroundStyle(.secondary)
                    Button("Open session to reply") { state.openSession(session) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("No question waiting").font(.callout.weight(.medium))
                    Text("This request has been resolved or the session has moved on.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Session unavailable").font(.callout)
            }
        }
        .padding(16).frame(width: 320).tint(agentAccent)
        .preferredColorScheme(.dark).disabled(!state.isActive)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("boring-agent-question-details")
    }
}

@MainActor
struct BoringAgentSettingsView: View {
    @ObservedObject var state: AgentDashboardState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("BoringAgent", systemImage: "gauge.with.dots.needle.50percent").font(.title2.bold())
                    Text("Your agents, usage, and questions in the notch.").foregroundStyle(.secondary)
                }
                ForEach(state.providers) { provider in
                    AgentProviderSettings(state: state, providerID: provider.id)
                }
                Text("Copy setup commands into Terminal only when you are ready to connect a provider. Select its private relay folder to authorize the host. The dashboard never submits answers or approves requests for you.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let message = state.actionMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
        .frame(minWidth: 420, idealWidth: 470, minHeight: 430)
        .disabled(!state.isActive)
    }
}

@MainActor
private struct AgentProviderSettings: View {
    @ObservedObject var state: AgentDashboardState
    let providerID: String
    var body: some View {
        if let provider = state.provider(forID: providerID) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        AgentProviderLogo(provider: provider, size: 22)
                        Text(provider.descriptor.title).font(.headline)
                        Spacer()
                    }
                    HStack {
                        Text("Session relay").font(.subheadline.weight(.medium))
                        Spacer()
                        Text(provider.connection.label).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("boring-agent-relay-status-\(providerID)")
                    }
                    if let message = provider.connection.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let message = provider.message, message != provider.connection.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let directory = provider.relayDirectory {
                        Text(directory).font(.caption.monospaced()).textSelection(.enabled)
                            .lineLimit(2).truncationMode(.middle)
                    }
                    if let command = provider.setupCommand {
                        HStack(alignment: .top, spacing: 8) {
                            Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Spacer(minLength: 0)
                            Button("Copy setup") { state.copySetupCommand(providerID: providerID) }
                        }
                        .padding(9).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if provider.connection.canConfigure {
                        HStack {
                            Button(provider.connection.isConnected ? "Change relay folder…" : "Choose relay folder…") {
                                state.connectProvider(providerID)
                            }
                            Button("Refresh relay") { state.refresh(providerID: providerID) }
                                .disabled(provider.usageIsRefreshing)
                            if provider.relayDirectory != nil {
                                Button("Disconnect relay") { state.disconnectProvider(providerID) }
                            }
                        }.controlSize(.small)
                    }
                    if let connection = provider.usageConnection {
                        Divider().padding(.vertical, 3)
                        HStack {
                            Text("Account usage").font(.subheadline.weight(.medium))
                            Spacer()
                            Text(connection.label).font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("boring-agent-usage-status-\(providerID)")
                        }
                        if let message = connection.message {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        AgentAccountUsageControls(state: state, providerID: providerID, showsConnectedControls: true)
                    }
                }.padding(5).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

@MainActor
struct BoringAgentActivityView: View {
    @ObservedObject var state: AgentDashboardState
    let region: Int32
    var body: some View {
        Button {
            if let session = state.attentionSession { state.openSession(session) }
        } label: {
            HStack(spacing: 5) {
                if region == 0 {
                    if let session = state.attentionSession,
                       let provider = state.provider(forID: session.providerID) {
                        AgentProviderLogo(provider: provider, size: 16)
                        Text(provider.descriptor.shortName).font(.system(size: 11, weight: .medium))
                    } else {
                        Image(systemName: "bubble.left").foregroundStyle(agentAccent)
                        Text("Agents").font(.system(size: 11, weight: .medium))
                    }
                } else {
                    Image(systemName: "bubble.left.fill").foregroundStyle(agentAccent)
                    Text("\(state.currentAttentionCount)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                }
            }
        }
        .buttonStyle(.plain).foregroundStyle(.white).fixedSize()
        .disabled(!state.isActive || state.attentionSession == nil)
        .accessibilityLabel("\(sessionCount(state.currentAttentionCount)) \(state.currentAttentionCount == 1 ? "needs" : "need") input. Open the most urgent session.")
        .accessibilityIdentifier(region == 0 ? "boring-agent-activity-leading" : "boring-agent-activity-trailing")
    }
}
