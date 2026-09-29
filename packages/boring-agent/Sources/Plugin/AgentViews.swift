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
    if let account = provider.usageAccount {
        switch account.state {
        case .connected: return .connected
        case .signInRequired: return .disconnected
        case .unavailable: return .unavailable(account.message)
        case .failed: return .failed(account.message)
        }
    }
    return provider.usageConnection ?? provider.connection
}

private func canRefreshUsage(_ provider: AgentProviderSnapshot) -> Bool {
    switch usageConnection(for: provider) {
    case .connected, .failed: return true
    case .disconnected: return provider.usageConnection == nil
    case .unavailable: return false
    }
}

private func supportsInlineMessage(_ session: AgentSession) -> Bool {
    guard let control = session.control else { return false }
    if let request = control.request { return !request.questions.contains(where: \.isSecret) }
    return control.canPrompt
}

private func sessionQuestionSummary(_ session: AgentSession) -> String? {
    if let request = session.control?.request {
        if request.questions.contains(where: \.isSecret) { return "Private input is needed in your session." }
        return request.questions.first?.prompt
    }
    return session.phase == .needsInput ? session.question : nil
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
        VStack(alignment: .leading, spacing: 6) {
            header
            if state.section == .usage {
                usage
            } else {
                AgentProgressView(state: state, compact: compact, width: layout.contentSize.width)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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
        HStack(spacing: 8) {
            Text("Agents")
                .font(.headline)
            Spacer(minLength: 8)
            Picker("Dashboard view", selection: $state.section) {
                Text("Progress").tag(AgentDashboardSection.progress)
                    .accessibilityIdentifier("boring-agent-section-progress")
                Text("Usage").tag(AgentDashboardSection.usage)
                    .accessibilityIdentifier("boring-agent-section-usage")
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .frame(width: compact ? 152 : 164)
            .accessibilityLabel("Dashboard view")
        }
        .frame(height: 22)
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
                VStack(spacing: 4) {
                    AgentUsageRing(provider: provider, size: compact ? 46 : 54)
                    Text(provider.descriptor.shortName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.86)).lineLimit(1)
                    Text(footnote(provider))
                        .font(compact ? .caption2 : .caption).monospacedDigit()
                        .foregroundStyle(.secondary).lineLimit(1)
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
        if provider.usageRefreshError != nil { return "Needs attention" }
        if provider.usageAccount?.state == .signInRequired { return "Sign in for usage" }
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
                            if provider.usageAccount == nil && usageConnection(for: provider).message == nil {
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
                    if provider.usageAccount == nil, let message = usageConnection(for: provider).message {
                        Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("boring-agent-connection-message-\(providerID)")
                    }
                    if provider.usageAccount != nil {
                        AgentSubscriptionUsageControls(state: state, providerID: providerID)
                    } else if provider.usageConnection != nil {
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
private struct AgentSubscriptionUsageControls: View {
    @ObservedObject var state: AgentDashboardState
    let providerID: String
    var showsRefreshControl = false
    @State private var copiedCommand: String?
    @State private var copyFailed = false

    var body: some View {
        if let provider = state.provider(forID: providerID), let account = provider.usageAccount {
            VStack(alignment: .leading, spacing: 9) {
                Text(providerID == "codex" ? "ChatGPT subscription usage" : "Subscription usage")
                    .font(.subheadline.weight(.medium))
                if providerID == "codex" {
                    Text("Account limits are separate from Azure and API session billing.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(account.message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("boring-agent-usage-account-message-\(providerID)")
                if let error = provider.usageRefreshError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("boring-agent-usage-refresh-error-\(providerID)")
                }
                if showsRefreshControl {
                    Button(provider.usageIsRefreshing ? "Refreshing usage…" : "Refresh usage") {
                        state.refreshUsage(providerID: providerID)
                    }
                    .disabled(provider.usageIsRefreshing)
                    .controlSize(.small)
                    .accessibilityIdentifier("boring-agent-refresh-subscription-\(providerID)")
                }
                if let usage = provider.usage {
                    Text("Captured \(Date(timeIntervalSince1970: usage.updatedAt).formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("boring-agent-usage-captured-\(providerID)")
                }
                if let command = account.signInCommand {
                    Text("Run this command in Terminal to sign in for usage. Your current sessions keep their existing provider.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(command).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).lineLimit(4).help(command)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                    Button(copiedCommand == command ? "Copied" : "Copy sign-in command") {
                        if state.copyUsageSignInCommand(providerID: providerID) {
                            copiedCommand = command; copyFailed = false
                        } else { copiedCommand = nil; copyFailed = true }
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("boring-agent-copy-usage-signin-\(providerID)")
                    if copyFailed {
                        Text("The command could not be copied. Select and copy it above.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

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
                    picker
                } else if let session = state.selectedSession {
                    ScrollView(.vertical) {
                        AgentSessionDetail(state: state, sessionID: session.id, compact: true)
                    }
                } else {
                    empty
                }
            } else {
                HStack(alignment: .top, spacing: 11) {
                    picker.frame(width: max(155, min(205, width * 0.35)))
                    Divider()
                    if let session = state.selectedSession {
                        ScrollView(.vertical) {
                            AgentSessionDetail(state: state, sessionID: session.id, compact: false)
                        }
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

    private var picker: some View {
        AgentSessionPicker(rows: state.visibleSessions.map { session in
            AgentSessionPickerRow(id: session.id, title: session.project, providerID: session.providerID,
                status: state.isStale(session) ? .stale : session.phase == .needsInput ? .waiting : session.phase == .working ? .working : .inactive,
                accessibilityLabel: "\(session.project), \(state.provider(forID: session.providerID)?.descriptor.title ?? session.providerID), \(state.statusLabel(session))")
        }, icons: pickerIcons, selectedID: state.selectedID, query: state.query,
            waitingOnly: state.waitingOnly, waitingCount: state.attentionCount,
            compact: compact, isEnabled: state.isActive,
            queryChanged: { state.query = $0 }, waitingChanged: { state.waitingOnly = $0 },
            selectionChanged: { state.select($0) },
            activateSelection: { if compact { state.compactSearch = false } },
            done: { state.compactSearch = false })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var pickerIcons: [String: AgentSessionPickerIcon] {
        Dictionary(uniqueKeysWithValues: state.providers.compactMap { provider in
            guard let asset = AgentLogoCache.asset(for: provider) else { return nil }
            return (provider.id, AgentSessionPickerIcon(image: asset.image, isTemplate: asset.template))
        })
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(state.sessions.isEmpty ? "Ready for your next session" : "No matching sessions")
                    .font(.caption.weight(.medium))
                if compact {
                    Spacer(minLength: 2)
                    Button("Search…", systemImage: "magnifyingglass") { state.compactSearch = true }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityLabel("Search agent sessions")
                }
            }
            Text(state.sessions.isEmpty ? "Connect a supported provider in Usage to see its activity here." : "Try another project or clear the waiting filter.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if state.sessions.isEmpty {
                Button("View providers") { state.section = .usage }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

@MainActor
private struct AgentSessionDetail: View {
    private struct MessageTarget: Identifiable { let id: String }
    private struct PendingMessageTarget {
        let target: MessageTarget
        let controlRevision: String?
        let requestID: String?
        let expiresAt: ContinuousClock.Instant
    }
    @ObservedObject var state: AgentDashboardState
    let sessionID: String
    let compact: Bool
    @State private var showingQuestion = false
    @State private var showingActionStatus = false
    @State private var messageTarget: MessageTarget?
    @State private var pendingMessageTarget: PendingMessageTarget?

    var body: some View {
        if let session = state.session(forID: sessionID) {
            VStack(alignment: .leading, spacing: 4) {
                header(session)
                if let question = sessionQuestionSummary(session) {
                    Button {
                        if supportsInlineMessage(session) { presentComposer(for: session) }
                        else { showingQuestion = true }
                    } label: {
                        HStack(alignment: .top, spacing: 4) {
                            Text(question).font(.caption.weight(.medium))
                                .lineLimit(compact ? 1 : 2).multilineTextAlignment(.leading)
                            Image(systemName: "chevron.right").font(.caption2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("View the full question and choices")
                    .accessibilityIdentifier("boring-agent-question")
                    .popover(isPresented: $showingQuestion, arrowEdge: .bottom) {
                        AgentQuestionPopover(state: state, sessionID: sessionID)
                    }
                } else {
                    Text(state.statusDescription(session)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).help(state.statusDescription(session))
                }
                footer(session)
                    .padding(.top, 2)
                actionStatus(session)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .id(session.id)
            .popover(item: $messageTarget, arrowEdge: .bottom) { target in
                AgentMessageComposer(state: state, sessionID: target.id)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                presentPendingComposer()
            }
            .onChange(of: sessionID) { _, _ in pendingMessageTarget = nil }
            .onChange(of: state.isActive) { _, active in
                if !active { pendingMessageTarget = nil }
            }
            .onDisappear { pendingMessageTarget = nil }
        }
    }

    private func presentComposer(for session: AgentSession) {
        showingQuestion = false
        showingActionStatus = false
        pendingMessageTarget = nil
        guard state.isActive, session.id == sessionID,
              let current = state.session(forID: session.id) else { return }
        let target = MessageTarget(id: session.id)
        guard supportsInlineMessage(current), !NSApp.isActive else {
            messageTarget = target
            return
        }
        // A nonactivating notch deliberately leaves the previous app active.
        // Opening an editor is explicit keyboard intent: activate before the
        // transient popover exists, so first typing cannot dismiss it mid-switch.
        // The notification, not an arbitrary delay, releases presentation.
        pendingMessageTarget = PendingMessageTarget(target: target,
            controlRevision: current.control?.revision, requestID: current.control?.request?.id,
            expiresAt: .now.advanced(by: .seconds(3)))
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentPendingComposer() {
        guard NSApp.isActive, let pending = pendingMessageTarget else { return }
        pendingMessageTarget = nil
        // A denied/delayed activation must not reopen an abandoned composer on
        // some later app activation or retarget the user's request to a new row.
        guard pending.expiresAt > .now, state.isActive,
              pending.target.id == sessionID,
              let current = state.session(forID: pending.target.id),
              current.control?.revision == pending.controlRevision,
              current.control?.request?.id == pending.requestID else { return }
        messageTarget = pending.target
    }

    private func header(_ session: AgentSession) -> some View {
        HStack(spacing: 6) {
            if let provider = state.provider(forID: session.providerID) {
                AgentProviderLogo(provider: provider, size: 12)
            }
            Text(session.project).font(.callout.weight(.semibold))
                .lineLimit(1).truncationMode(.middle).help(session.directory)
            Spacer(minLength: 2)
            if state.isStale(session) {
                Text("Stale").font(.caption).foregroundStyle(.secondary)
            }
            if compact {
                Button { state.compactSearch = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "magnifyingglass")
                        Text("\(state.visibleSessions.count)").monospacedDigit()
                    }.font(.caption)
                        .frame(minWidth: 32, minHeight: 22)
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Search sessions")
                .accessibilityLabel("Search \(sessionCount(state.visibleSessions.count))")
                .accessibilityIdentifier("boring-agent-open-search")
            } else if let model = session.model {
                Text(model).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(minHeight: 20)
    }

    private func footer(_ session: AgentSession) -> some View {
        HStack(spacing: 8) {
            Button {
                if supportsInlineMessage(session) { presentComposer(for: session) }
                else { state.openSession(session) }
            } label: {
                Label(primaryActionTitle(session), systemImage: supportsInlineMessage(session) ? "bubble.left" : "arrow.up.right")
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .fixedSize().layoutPriority(1)
            .help(session.control?.unavailableReason ?? primaryActionTitle(session))
            .accessibilityIdentifier(supportsInlineMessage(session) ? "boring-agent-compose-message" : "boring-agent-open-session")
            Menu {
                Button("Open session") { state.openSession(session) }
                Button("Open original app") { state.openOriginApp(session) }
                Button("Copy resume command") { state.copyResumeCommand(session) }
                Button("Refresh provider") { state.refresh(providerID: session.providerID) }
                if supportsInlineMessage(session) {
                    Button(session.control?.request == nil ? "Write message…" : "Reply here…") {
                        presentComposer(for: session)
                    }
                } else {
                    Button("Messaging availability…") { presentComposer(for: session) }
                    if session.phase == .needsInput { Button("View question and choices") { showingQuestion = true } }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 22, height: 22) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .controlSize(.small).fixedSize()
            .accessibilityLabel("Session actions")
            .help("Session actions")
            Spacer(minLength: 8)
            if compact {
                HStack(spacing: 0) {
                    Button { state.moveSelection(-1) } label: {
                        Image(systemName: "chevron.up").frame(width: 22, height: 22)
                    }
                    .accessibilityLabel("Previous session").help("Previous session")
                    Button { state.moveSelection(1) } label: {
                        Image(systemName: "chevron.down").frame(width: 22, height: 22)
                    }
                    .accessibilityLabel("Next session").help("Next session")
                }
                .buttonStyle(.borderless).font(.caption)
                .disabled(state.visibleSessions.count < 2)
            }
        }
        .frame(minHeight: 22)
    }

    @ViewBuilder
    private func actionStatus(_ session: AgentSession) -> some View {
        if let status = state.messageStatus(for: sessionID) {
            let kind = status.requestID == nil ? "message" : "reply"
            let outcome = switch status.delivery {
            case .accepted: "Accepted"
            case .rejected: "Rejected"
            default: "Delivery unconfirmed"
            }
            statusDetails(status.pending ? "Sending \(kind)…" : "Last \(kind): \(outcome)", detail: status.message)
                .accessibilityIdentifier("boring-agent-message-status-summary")
        } else if let message = state.actionMessage {
            statusDetails("Action status", detail: message)
        } else if let remaining = session.contextRemaining {
            Text("Context remaining: \(Int(remaining.rounded()))%")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .help("Session context remaining; separate from subscription allowance")
        }
    }

    private func statusDetails(_ title: String, detail: String) -> some View {
        Button {
            messageTarget = nil
            showingQuestion = false
            showingActionStatus = true
        } label: {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Image(systemName: "info.circle").accessibilityHidden(true)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary)
        .help(detail).accessibilityLabel("\(title). \(detail)")
        .popover(isPresented: $showingActionStatus, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(detail).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(width: 260, alignment: .leading)
        }
    }

    private func primaryActionTitle(_ session: AgentSession) -> String {
        if supportsInlineMessage(session) { return session.control?.request == nil ? "Message" : "Reply" }
        return session.phase == .needsInput || session.control?.request != nil ? "Reply in session" : "Open session"
    }
}

private enum AgentComposerInput: Hashable {
    case prompt
    case answer(String)
}

/// Both providers use the same current-owner contract. Text lives in the model,
/// never in a global field or a view-local draft, so remounts retain the right
/// session's draft and a changed turn cannot silently inherit a previous send.
@MainActor
private struct AgentMessageComposer: View {
    @ObservedObject var state: AgentDashboardState
    let sessionID: String
    @State private var promptTooLong = false
    @FocusState private var focusedInput: AgentComposerInput?
    @State private var focusRequestID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let session = state.session(forID: sessionID) {
                targetHeader(session)
                if let control = session.control {
                    let draft = state.draft(for: sessionID)
                    let changed = draft.revision != control.revision || draft.requestID != control.request?.id
                    let pending = state.messageStatus(for: sessionID)?.pending == true
                    let currentStatus = state.currentMessageStatus(for: sessionID)
                    if changed {
                        VStack(alignment: .leading, spacing: 7) {
                            Label("Session changed. Review the current request.", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Review current request") {
                                state.refreshDraft(for: sessionID)
                                requestInputFocus()
                            }
                                .disabled(pending)
                                .accessibilityIdentifier("boring-agent-review-draft")
                        }
                        .padding(10).background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if let reason = control.unavailableReason {
                        Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let request = control.request {
                        if request.questions.contains(where: \.isSecret) {
                            Text("This request needs private input. Open the original session to reply.")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("boring-agent-secret-handoff")
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 18) {
                                    ForEach(request.questions) { question in
                                        AgentQuestionEditor(state: state, sessionID: sessionID,
                                            revision: control.revision, requestID: request.id,
                                            question: question, focusedInput: $focusedInput)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.trailing, 4)
                            }
                            .frame(height: min(280, CGFloat(request.questions.count) * 155 + CGFloat(request.questions.first?.options.count ?? 0) * 24))
                            .disabled(changed || pending)
                            Text("Answer each question, then choose Send. Nothing is sent when you select an option.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if control.canPrompt {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Message").font(.system(size: 12, weight: .medium))
                            TextEditor(text: promptBinding(revision: control.revision))
                                .focused($focusedInput, equals: .prompt)
                                .font(.system(size: 12))
                                .scrollContentBackground(.hidden)
                                .padding(7)
                                .frame(height: 115)
                                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.12), lineWidth: 1))
                                .disabled(changed || pending)
                                .accessibilityLabel("Message to \(session.project)")
                                .accessibilityIdentifier("boring-agent-message-text")
                            if promptTooLong {
                                Text("Message is too long. Shorten it before sending.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    } else if control.unavailableReason == nil {
                        unavailableExplanation
                    }
                    if let status = currentStatus {
                        AgentMessageStatusView(status: status)
                    } else if pending {
                        Text("Waiting for the previous message’s delivery result.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Open session") { state.openSession(session) }
                            .buttonStyle(.bordered)
                        Spacer()
                        if supportsInlineMessage(session) {
                            Button(currentStatus?.pending == true ? "Sending…" : "Send") {
                                guard let current = state.session(forID: sessionID)?.control,
                                      current.revision == control.revision,
                                      current.request?.id == control.request?.id else { return }
                                state.sendDraft(for: sessionID)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(changed || pending || !state.canSendDraft(for: sessionID))
                            .accessibilityIdentifier("boring-agent-send-message")
                        }
                    }
                    .controlSize(.small)
                } else {
                    unavailableExplanation
                    Button("Open session") { state.openSession(session) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Text("Session unavailable").font(.callout)
                Text("This session is no longer registered.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(width: 350)
        .tint(agentAccent).preferredColorScheme(.dark)
        .disabled(!state.isActive)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("boring-agent-message-composer")
        .background {
            AgentComposerKeyboardFocus(requestID: editableInput == nil ? nil : focusRequestID) { id in
                guard id == focusRequestID, let input = editableInput else { return }
                focusedInput = input
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .task {
            // This view exists only after an explicit Message/Reply action.
            // Allow the native popover to mount before requesting its editor;
            // never take focus when the dashboard tab itself mounts or updates.
            await Task.yield()
            guard !Task.isCancelled else { return }
            requestInputFocus()
        }
    }

    private func requestInputFocus() {
        guard editableInput != nil else { return }
        focusRequestID = UUID()
    }

    private var editableInput: AgentComposerInput? {
        guard state.isActive,
              state.messageStatus(for: sessionID)?.pending != true,
              let control = state.session(forID: sessionID)?.control else { return nil }
        let draft = state.draft(for: sessionID)
        guard draft.revision == control.revision, draft.requestID == control.request?.id else { return nil }
        if let request = control.request {
            guard !request.questions.contains(where: \.isSecret), let first = request.questions.first else { return nil }
            return .answer(first.id)
        } else if control.canPrompt {
            return .prompt
        }
        return nil
    }

    private func targetHeader(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if let provider = state.provider(forID: session.providerID) {
                    AgentProviderLogo(provider: provider, size: 20)
                    Text(provider.descriptor.title).font(.headline)
                }
                Spacer()
                Text(session.control?.request == nil ? "Message" : "Reply")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(session.project).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .help(session.directory)
            Text("Session \(session.nativeID)").font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled).help(session.nativeID)
                .accessibilityIdentifier("boring-agent-message-target")
        }
    }

    private var unavailableExplanation: some View {
        Text("This session does not support messages from the notch. Continue in the original session.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func promptBinding(revision: String) -> Binding<String> {
        Binding(get: { state.draft(for: sessionID).text }, set: { text in
            guard let control = state.session(forID: sessionID)?.control,
                  control.revision == revision, control.request == nil, control.canPrompt,
                  state.draft(for: sessionID).revision == revision else { return }
            promptTooLong = text.utf8.count > AgentMessageCommand.maximumTextBytes
            if !promptTooLong { state.setDraftText(text, for: sessionID) }
        })
    }
}

@MainActor
private struct AgentQuestionEditor: View {
    @ObservedObject var state: AgentDashboardState
    let sessionID: String
    let revision: String
    let requestID: String
    let question: AgentInputQuestion
    let focusedInput: FocusState<AgentComposerInput?>.Binding
    @State private var answerTooLong = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !question.title.isEmpty {
                Text(question.title).font(.system(size: 12, weight: .semibold))
            }
            Text(question.prompt).font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if !question.options.isEmpty {
                Text(question.allowsMultiple ? "Choose any that apply, or add an answer." : "Choose one, or write an answer.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    let selected = (state.draft(for: sessionID).answers[question.id] ?? []).contains(option)
                    Button { toggle(option) } label: {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: question.allowsMultiple
                                  ? (selected ? "checkmark.square.fill" : "square")
                                  : (selected ? "largecircle.fill.circle" : "circle"))
                                .foregroundStyle(selected ? agentAccent : .secondary)
                            Text(option).font(.system(size: 11))
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected ? agentAccent.opacity(0.13) : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("boring-agent-answer-\(question.id)-option-\(index)")
                }
            }
            TextField(question.options.isEmpty ? "Your answer" : "Write an answer", text: customAnswer, axis: .vertical)
                .focused(focusedInput, equals: .answer(question.id))
                .textFieldStyle(.roundedBorder).font(.system(size: 12)).lineLimit(2...5)
                .accessibilityLabel("Written answer for \(question.title.isEmpty ? question.prompt : question.title)")
                .accessibilityIdentifier("boring-agent-answer-\(question.id)-text")
            if answerTooLong {
                Text("Reply is too long. Shorten an answer before continuing.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var isCurrent: Bool {
        guard let control = state.session(forID: sessionID)?.control else { return false }
        let draft = state.draft(for: sessionID)
        return control.revision == revision && control.request?.id == requestID &&
            draft.revision == revision && draft.requestID == requestID && !question.isSecret
    }

    private var customAnswer: Binding<String> {
        Binding(get: {
            (state.draft(for: sessionID).answers[question.id] ?? []).first { !question.options.contains($0) } ?? ""
        }, set: { text in
            guard isCurrent else { return }
            var values = question.allowsMultiple
                ? (state.draft(for: sessionID).answers[question.id] ?? []).filter { question.options.contains($0) }
                : []
            if !text.isEmpty { values.append(text) }
            update(values)
        })
    }

    private func toggle(_ option: String) {
        guard isCurrent else { return }
        var values = state.draft(for: sessionID).answers[question.id] ?? []
        if question.allowsMultiple {
            if values.contains(option) { values.removeAll { $0 == option } }
            else { values.append(option) }
        } else {
            values = [option]
        }
        update(values)
    }

    private func update(_ values: [String]) {
        var answers = state.draft(for: sessionID).answers
        if values.isEmpty { answers.removeValue(forKey: question.id) }
        else { answers[question.id] = values }
        answerTooLong = answers.values.flatMap { $0 }.reduce(0, { $0 + $1.utf8.count }) > AgentMessageCommand.maximumTextBytes
        if !answerTooLong { state.setDraftAnswers(answers, for: sessionID) }
    }
}

private struct AgentMessageStatusView: View {
    let status: AgentMessageStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
            Text(status.message).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if status.delivery == .unknown {
                Text("Check the original session before sending again. The previous message may have arrived.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("boring-agent-message-status")
    }

    private var title: String {
        if status.pending { return "Sending…" }
        switch status.delivery {
        case .accepted: return "Accepted by the session"
        case .rejected: return "Message rejected"
        case .unknown: return "Delivery unconfirmed"
        default: return "Message status"
        }
    }

    private var symbol: String {
        if status.pending { return "clock" }
        switch status.delivery {
        case .accepted: return "checkmark.circle"
        case .rejected, .unknown: return "exclamationmark.circle"
        default: return "info.circle"
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
                if session.control?.request?.questions.contains(where: \.isSecret) == true {
                    Text("This request needs private input. Open the original session to reply.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button("Open session to reply") { state.openSession(session) }
                        .buttonStyle(.borderedProminent)
                } else if session.phase == .needsInput, let question = session.question {
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
                    if let reason = session.control?.unavailableReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                Text("Copy setup commands into Terminal only when you are ready to connect a provider. Select its private relay folder to authorize the host. Messages are sent only when you choose Send. Permission approvals stay in the original session.")
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
                    if provider.inlineRepliesEnabled != nil || provider.messagingSetupCommand != nil {
                        Divider().padding(.vertical, 3)
                        AgentMessagingSettings(state: state, providerID: providerID)
                    }
                    if provider.usageAccount != nil {
                        Divider().padding(.vertical, 3)
                        AgentSubscriptionUsageControls(state: state, providerID: providerID, showsRefreshControl: true)
                    } else if let connection = provider.usageConnection {
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
private struct AgentMessagingSettings: View {
    @ObservedObject var state: AgentDashboardState
    let providerID: String

    var body: some View {
        if let provider = state.provider(forID: providerID) {
            VStack(alignment: .leading, spacing: 10) {
                if provider.inlineRepliesEnabled != nil {
                    Toggle("Reply to questions in the notch", isOn: Binding(
                        get: { state.provider(forID: providerID)?.inlineRepliesEnabled ?? false },
                        set: { state.setInlineRepliesEnabled($0, providerID: providerID) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!provider.connection.isConnected)
                    .accessibilityIdentifier("boring-agent-inline-replies-\(providerID)")
                    Text("Answer future Claude questions from the notch. If no reply arrives within 90 seconds, Claude shows its original prompt. Tool permissions stay in Claude.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !provider.connection.isConnected {
                        Text("Connect the session relay to change this setting.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let command = provider.messagingSetupCommand {
                    Text("Prompting sessions").font(.subheadline.weight(.medium))
                    Text("Sending new prompts requires a Claude Code CLI session explicitly started with this command. Run it in the project you want to work on.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 8) {
                        Text(command).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).lineLimit(4).help(command)
                        Spacer(minLength: 0)
                        Button("Copy command") { state.copyMessagingSetupCommand(providerID: providerID) }
                            .accessibilityIdentifier("boring-agent-copy-messaging-setup-\(providerID)")
                    }
                    .padding(9).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
