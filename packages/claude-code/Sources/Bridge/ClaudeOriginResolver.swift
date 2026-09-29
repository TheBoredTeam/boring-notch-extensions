// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import Darwin

enum ClaudeOriginResolver {
    static let supportedApps: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.anthropic.claudefordesktop",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"]

    static func info(_ pid: Int32) -> proc_bsdinfo? {
        guard pid > 1 else { return nil }
        var result = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &result, Int32(MemoryLayout<proc_bsdinfo>.size))
        return count == MemoryLayout<proc_bsdinfo>.size && result.pbi_uid == getuid() ? result : nil
    }

    static func path(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func capture(environment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeOrigin {
        var result = ClaudeOrigin()
        if let remote = environment["CLAUDE_CODE_BRIDGE_SESSION_ID"], ClaudeValidation.remoteID(remote) { result.remoteSessionID = remote }
        guard let value = environment["CLAUDE_PID"], let pid = Int32(value), let initial = info(pid),
              let executable = path(pid), looksLikeClaude(executable) else { return result }
        result.claudePID = pid
        result.processStartTime = Double(initial.pbi_start_tvsec) + Double(initial.pbi_start_tvusec) / 1_000_000
        var ancestor = pid
        var visited: Set<Int32> = []
        for _ in 0..<32 {
            guard ancestor > 1, !visited.contains(ancestor), let details = info(ancestor) else { break }
            visited.insert(ancestor)
            if result.tty == nil, let device = devname(dev_t(bitPattern: details.e_tdev), S_IFCHR) {
                let tty = "/dev/" + String(cString: device)
                if validTTY(tty) { result.tty = tty }
            }
            if let executable = path(ancestor), let range = executable.range(of: ".app/Contents/") {
                let appPath = String(executable[..<range.lowerBound]) + ".app"
                if let bundleID = Bundle(path: appPath)?.bundleIdentifier, supportedApps.contains(bundleID) {
                    result.appBundleID = bundleID
                    result.appPath = appPath
                    break
                }
            }
            ancestor = Int32(details.pbi_ppid)
        }
        return result
    }

    static func validTTY(_ value: String) -> Bool {
        value.range(of: #"^/dev/ttys[0-9]{1,8}$"#, options: .regularExpression) != nil
    }

    static func looksLikeClaude(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if name == "claude" { return true }
        // The native installer launches version-named binaries through ~/.local/bin/claude.
        return path.contains("/claude/versions/") && name.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil
    }

    static func verified(_ origin: ClaudeOrigin) -> Bool {
        guard let pid = origin.claudePID, let expected = origin.processStartTime,
              let current = info(pid), let executable = path(pid),
              looksLikeClaude(executable) else { return false }
        let actual = Double(current.pbi_start_tvsec) + Double(current.pbi_start_tvusec) / 1_000_000
        return abs(expected - actual) < 0.0001
    }

    static func focus(_ session: ClaudeSession, allowUI: Bool = true) -> ClaudeFocusReceipt {
        func receipt(_ status: String, _ message: String) -> ClaudeFocusReceipt {
            ClaudeFocusReceipt(sessionID: session.id, status: status, message: message, updatedAt: Date().timeIntervalSince1970)
        }
        guard allowUI else { return receipt("unavailable", "The broker is running in validation mode; no app was opened.") }
        guard verified(session.origin) else {
            return receipt("unavailable", "The original Claude process is no longer verified. Copy the resume command to recover this session.")
        }
        let current = capture(environment: ["CLAUDE_PID": String(session.origin.claudePID ?? 0)])
        if let remote = session.origin.remoteSessionID, ClaudeValidation.remoteID(remote),
           let url = URL(string: "https://claude.ai/code/" + remote), NSWorkspace.shared.open(url) {
            return receipt("focused", "Opened the existing Remote Control session. Reply in Claude.")
        }
        guard let bundleID = current.appBundleID, supportedApps.contains(bundleID),
              bundleID == session.origin.appBundleID else {
            return receipt("unavailable", "The originating app could not be verified. Copy the resume command to recover this session.")
        }
        if let tty = session.origin.tty, tty == current.tty, validTTY(tty),
           ["com.apple.Terminal", "com.googlecode.iterm2"].contains(bundleID) {
            let script: String
            if bundleID == "com.apple.Terminal" {
                script = """
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set selected tab of w to t
                                set index of w to 1
                                activate
                                return "focused"
                            end if
                        end repeat
                    end repeat
                end tell
                return "not-found"
                """
            } else {
                script = """
                tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    select s
                                    select t
                                    select w
                                    activate
                                    return "focused"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return "not-found"
                """
            }
            var error: NSDictionary?
            if NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue == "focused" {
                return receipt("focused", "Selected the original terminal session. Reply in Claude.")
            }
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.bundleURL?.path == current.appPath }), app.activate(options: []) {
            return receipt("appOpened", "Opened the originating app. Select this session there; exact session focus was unavailable.")
        }
        return receipt("unavailable", "The original app could not be opened. Copy the resume command to recover this session.")
    }
}
