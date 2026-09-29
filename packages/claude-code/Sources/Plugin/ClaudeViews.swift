// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

private let claudeAccent = Color(red: 0.89, green: 0.55, blue: 0.39)

private func claudeSessionCount(_ count: Int) -> String {
    "\(count) \(count == 1 ? "session" : "sessions")"
}

@MainActor
private struct ClaudeLogo: View {
    var size: CGFloat = 16
    var body: some View {
        if let image = ClaudePluginResources.logo {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(claudeAccent)
                .accessibilityHidden(true)
        }
    }
}

@MainActor
struct ClaudeTabView: View {
    @ObservedObject var state: ClaudePluginState
    let layout: ClaudeTabLayout

    var body: some View {
        Group {
            if !state.isConnected {
                ClaudeConnectionView(state: state, compact: layout.presentation == .compact)
            } else if layout.presentation == .compact || layout.contentSize.width < 440 {
                compact
            } else {
                regular
            }
        }
        .padding(layout.presentation == .compact ? 8 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.001))
        .foregroundStyle(.white)
        .tint(claudeAccent)
        .preferredColorScheme(.dark)
        .disabled(!state.isActive)
        .clipped()
    }

    private var regular: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 5) {
                ClaudeSearchField(state: state)
                HStack(spacing: 5) {
                    Text(claudeSessionCount(state.visibleSessions.count))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    waitingFilter
                }
                sessionList(compact: false)
            }
            .frame(width: max(140, min(200, layout.contentSize.width * 0.34)))
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1)
            if let session = state.selectedSession {
                ClaudeSessionDetail(state: state, session: session, compact: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                empty
            }
        }
    }

    private var compact: some View {
        VStack(alignment: .leading, spacing: 5) {
            if state.compactSearch {
                HStack(spacing: 6) {
                    ClaudeSearchField(state: state)
                    Button {
                        state.compactSearch = false
                    } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Close session search")
                }
                HStack {
                    Text(claudeSessionCount(state.visibleSessions.count)).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    waitingFilter
                }
                sessionList(compact: true)
            } else if let session = state.selectedSession {
                ClaudeSessionDetail(state: state, session: session, compact: true)
            } else {
                HStack {
                    Label { Text("Claude") } icon: { ClaudeLogo(size: 13) }
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button { state.compactSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.plain).accessibilityLabel("Search Claude sessions")
                }
                empty
            }
        }
    }

    private var waitingFilter: some View {
        Button { state.waitingOnly.toggle() } label: {
            Text("Waiting \(state.attentionCount)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(state.waitingOnly ? claudeAccent : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.waitingOnly ? "Show all sessions" : "Show waiting sessions")
        .accessibilityIdentifier("claude-waiting-filter")
    }

    private func sessionList(compact: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(state.visibleSessions) { session in
                        Button {
                            state.select(session.id)
                            if compact { state.compactSearch = false }
                        } label: {
                            ClaudeSessionRow(session: session, selected: state.selectedID == session.id,
                                             stale: state.isStale(session))
                        }
                        .buttonStyle(.plain)
                        .id(session.id)
                        .accessibilityLabel("\(session.project), \(state.statusLabel(session))")
                        .accessibilityIdentifier("claude-session-\(session.id)")
                    }
                }
            }
            .onAppear {
                // The durable selection can predate this controller mount.
                // Reveal it immediately, without animating through other rows.
                if let id = state.selectedID { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: state.selectedID) { _, id in
                // Instant scrolling respects Reduced Motion and makes far-end
                // selection visible without animating through 1,000 rows.
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(state.sessions.isEmpty ? "Ready for your next session" : "No matching sessions")
                .font(.system(size: 12, weight: .medium))
            Text(state.sessions.isEmpty ? "Start Claude Code after installing the relay hooks." : "Try a project name, session ID, or clear the waiting filter.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

@MainActor
private struct ClaudeSearchField: View {
    @ObservedObject var state: ClaudePluginState
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
            TextField("Search sessions", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .accessibilityIdentifier("claude-session-search")
            if !state.query.isEmpty {
                Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear session search")
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct ClaudeSessionRow: View {
    let session: ClaudeSession
    let selected: Bool
    let stale: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(stale ? .gray : session.phase == .needsInput ? claudeAccent : session.phase == .working ? .green : .gray)
                .frame(width: 5, height: 5)
            Text(session.project).font(.system(size: 11, weight: selected ? .medium : .regular))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 1)
            if session.phase == .needsInput {
                Image(systemName: stale ? "clock" : "bubble.left").font(.system(size: 9))
                    .foregroundStyle(stale ? .gray : claudeAccent)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(selected ? claudeAccent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
    }
}

@MainActor
private struct ClaudeSessionDetail: View {
    @ObservedObject var state: ClaudePluginState
    let session: ClaudeSession
    let compact: Bool
    @State private var showingQuestion = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 5) {
            header
            if let question = session.question, session.phase == .needsInput {
                Button { showingQuestion = true } label: {
                    HStack(alignment: .top, spacing: 5) {
                        Text(question).font(.system(size: compact ? 11 : 12, weight: .medium))
                            .lineLimit(compact ? 2 : 2).multilineTextAlignment(.leading)
                        Image(systemName: "arrow.up.right").font(.system(size: 8)).padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.92))
                .help("View the complete question and choices")
                .accessibilityLabel("Question: \(question). Show details")
                .popover(isPresented: $showingQuestion, arrowEdge: .bottom) {
                    ClaudeQuestionPopover(state: state, session: session)
                }
            } else {
                HStack(spacing: 5) {
                    Text(state.statusDescription(session))
                        .lineLimit(1)
                        .help(state.statusDescription(session))
                    if !compact, let model = session.model { Text("· \(model)").lineLimit(1) }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ClaudeUsageView(usage: session.usage, now: state.now)
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(session.id)
    }

    private var header: some View {
        HStack(spacing: 6) {
            ClaudeLogo(size: 14)
            Text(session.project).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                .help(session.directory)
            Spacer(minLength: 1)
            if compact {
                if state.isStale(session) {
                    Text("Stale").font(.system(size: 9)).foregroundStyle(.secondary)
                        .help(state.statusDescription(session))
                }
                Button { state.compactSearch = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "magnifyingglass")
                        Text("\(state.visibleSessions.count)").monospacedDigit()
                    }.font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Search \(claudeSessionCount(state.visibleSessions.count)) in Claude")
                .accessibilityIdentifier("claude-open-search")
            } else {
                Text(state.statusLabel(session)).font(.system(size: 9, weight: .medium))
                    .foregroundStyle(session.phase == .needsInput && !state.isStale(session) ? claudeAccent : .secondary)
                    .help(state.statusDescription(session))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button { state.openSession(session) } label: {
                Label(session.phase == .needsInput ? "Reply in session" : "Open session", systemImage: "arrow.up.right")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderedProminent).controlSize(.mini)
            .accessibilityIdentifier("claude-open-session")
            Menu {
                Button("Open original app") { state.openOriginApp(session) }
                Button("Copy resume command") {
                    state.copy("claude --resume \(session.id)", message: "Resume command copied. Run it in your terminal.")
                }
                Divider()
                Button("Refresh relay") { state.refresh() }
                if session.phase == .needsInput {
                    Button("View question and choices") { showingQuestion = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton).fixedSize().frame(width: 19)
            .accessibilityLabel("Session actions")
            if let message = state.actionMessage {
                Text(message).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    .help(message).accessibilityLabel(message)
            } else if compact {
                Spacer(minLength: 0)
                Button { state.moveSelection(-1) } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel("Previous session")
                Button { state.moveSelection(1) } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Next session")
            } else if let model = session.model {
                Spacer(minLength: 0)
                Text(model).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ClaudeUsageView: View {
    let usage: ClaudeUsage?
    let now: Date
    private var stale: Bool {
        guard let usage else { return false }
        return now.timeIntervalSince1970 - usage.updatedAt > 300
    }

    var body: some View {
        HStack(spacing: 9) {
            quota("5h", remaining: usage?.fiveHour?.remainingPercent, reset: usage?.fiveHour?.resetsAt)
            quota("7d", remaining: usage?.sevenDay?.remainingPercent, reset: usage?.sevenDay?.resetsAt)
            quota("Context", remaining: usage?.contextRemaining, reset: nil)
            if stale {
                Text("Stale").font(.system(size: 8)).foregroundStyle(.secondary)
                    .help("Usage snapshot is older than five minutes")
                    .accessibilityLabel("Usage is stale")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Remaining usage\(stale ? ", stale snapshot" : "")")
    }

    private func quota(_ label: String, remaining: Double?, reset: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text(label).foregroundStyle(.secondary)
                Text(remaining.map { "\(Int($0.rounded()))%" } ?? "—")
                    .foregroundStyle(remaining == nil ? .secondary : .primary).monospacedDigit()
            }
            .font(.system(size: 9, weight: .medium))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    if let remaining {
                        Capsule().fill(remaining < 15 ? Color.orange : claudeAccent)
                            .frame(width: geometry.size.width * min(1, max(0, remaining / 100)))
                    }
                }
            }
            .frame(height: 2)
        }
        .frame(maxWidth: .infinity)
        .help(help(label, remaining: remaining, reset: reset))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help(label, remaining: remaining, reset: reset))
    }

    private func help(_ label: String, remaining: Double?, reset: Double?) -> String {
        let title = label == "Context" ? "Session context remaining" : "\(label) subscription allowance remaining"
        guard let remaining else { return "\(title): unavailable. Claude has not supplied this value." }
        var text = "\(title): \(Int(remaining.rounded())) percent\(stale ? ". Stale snapshot" : "")"
        if let reset { text += ". Resets \(Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened))" }
        return text
    }
}

@MainActor
private struct ClaudeQuestionPopover: View {
    @ObservedObject var state: ClaudePluginState
    let session: ClaudeSession
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Claude needs your input", systemImage: "bubble.left")
                .font(.headline).foregroundStyle(claudeAccent)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.question ?? "Your session is waiting for input.")
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(session.questionOptions.enumerated()), id: \.offset) { index, option in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(option).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 220)
            Text("Reply or approve in Claude. The notch never sends answers or accepts permissions for you.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open session to reply") { state.openSession(session) }
                .buttonStyle(.borderedProminent).tint(claudeAccent)
        }
        .padding(16).frame(width: 320).disabled(!state.isActive)
    }
}

@MainActor
private struct ClaudeConnectionView: View {
    @ObservedObject var state: ClaudePluginState
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text(state.connection.label) } icon: { ClaudeLogo(size: compact ? 14 : 16) }
                .font(.system(size: compact ? 12 : 14, weight: .semibold)).foregroundStyle(claudeAccent)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).lineLimit(compact ? 2 : 3)
            HStack {
                Button("Choose relay folder") { state.chooseDirectory() }
                    .buttonStyle(.borderedProminent)
                Button("Copy setup command") {
                    state.copySetupCommand()
                }
                .buttonStyle(.bordered)
                .disabled(ClaudePluginResources.setupCommand == nil)
            }.controlSize(.mini)
            if let message = state.actionMessage {
                Text(message).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
    private var detail: String {
        if case .failed(let message) = state.connection { return message }
        return "Install the separate relay, then connect its folder. Session content stays on your Mac."
    }
}

@MainActor
struct ClaudeSettingsView: View {
    @ObservedObject var state: ClaudePluginState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label { Text("Claude Code") } icon: { ClaudeLogo(size: 24) }
                        .font(.title2.bold())
                    Text("Your sessions, questions, and usage in the notch.").foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(state.connection.label, systemImage: state.isConnected ? "checkmark.circle.fill" : "folder")
                            .foregroundStyle(state.isConnected ? .green : .secondary)
                        if let directory = state.directory {
                            Text(directory.path).font(.caption.monospaced()).textSelection(.enabled)
                                .lineLimit(2).truncationMode(.middle)
                        }
                        if case .failed(let message) = state.connection {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(state.directory == nil ? "Choose relay folder…" : "Change folder…") { state.chooseDirectory() }
                            if state.directory != nil {
                                Button("Refresh") { state.refresh() }
                                Button("Disconnect") { state.disconnect() }
                            }
                        }
                        if state.isConnected {
                            Text("\(claudeSessionCount(state.sessions.count)) · \(state.attentionCount) waiting for you")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect Claude Code").font(.headline)
                    Text("1. Copy and run the command below in Terminal. It uses the relay inside this installed extension.\n2. Follow the relay setup instructions.\n3. Choose the private relay folder printed by the command.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(ClaudePluginResources.setupCommand ?? "Bundled relay missing. Reinstall the complete extension package.")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy") { state.copySetupCommand() }
                            .disabled(ClaudePluginResources.setupCommand == nil)
                    }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    Link("Setup and uninstall instructions", destination: URL(string: "https://github.com/TheBoredTeam/boring-notch-extensions/tree/main/packages/claude-code")!)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Designed to stay local").font(.headline)
                    Text("The extension reads only your chosen relay folder. It does not read transcripts, credentials, or your Claude configuration. The relay stores session metadata and unanswered questions. Five-hour and seven-day allowances appear only when Claude supplies them; context is shown separately.")
                    Text("Reply in the original session. Remote Control opens its existing web session; terminal focus needs the separately running relay. Desktop falls back to opening the app because it has no supported per-session link.")
                }
                .font(.caption).foregroundStyle(.secondary)
                if let message = state.actionMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            }.padding(20)
        }
        .frame(minWidth: 420, idealWidth: 470, minHeight: 430)
        .disabled(!state.isActive)
    }
}

@MainActor
struct ClaudeActivityView: View {
    @ObservedObject var state: ClaudePluginState
    let region: Int32
    var body: some View {
        Button {
            if let session = state.attentionSession { state.openSession(session) }
        } label: {
            if region == 0 {
                HStack(spacing: 5) {
                    ClaudeLogo()
                    Text("Claude").font(.system(size: 11, weight: .medium))
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.fill").foregroundStyle(claudeAccent)
                    Text("\(state.currentAttentionCount)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                }
            }
        }
        .buttonStyle(.plain).foregroundStyle(.white).fixedSize()
        .disabled(!state.isActive || state.attentionSession == nil)
        .accessibilityLabel("Claude: \(claudeSessionCount(state.currentAttentionCount)) \(state.currentAttentionCount == 1 ? "needs" : "need") input. Open the most urgent session.")
    }
}
