// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation
import CryptoKit

/// App-server wire data is reduced here before it reaches private relay storage.
/// Conversation previews, transcripts, account identities and credentials are
/// deliberately absent from the shared presentation model.
enum CodexProtocol {
    static let providerID = "codex"

    static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    static func text(_ value: Any?, limit: Int) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= limit,
              !value.contains("\0") else { return nil }
        return value
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    static func requestKey(_ value: Any) -> String? {
        // Preserve numeric versus string request identities. These are JSON-RPC
        // server request IDs, not newly generated client request IDs.
        if let string = value as? String, string.utf8.count <= 256 { return "s:" + string }
        if let n = number(value), n.rounded() == n, abs(n) < 9_007_199_254_740_992 { return "n:" + String(format: "%.0f", n) }
        return nil
    }

    static func opaqueID(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func session(_ value: [String: Any], now: Date = Date()) -> AgentSession? {
        guard let id = identifier(value["id"]), let cwd = text(value["cwd"], limit: 4096),
              cwd.hasPrefix("/"), let created = number(value["createdAt"]), created > 0,
              let updated = number(value["updatedAt"]), updated > 0 else { return nil }
        // A subagent cannot be addressed as an ordinary top-level conversation.
        guard identifier(value["parentThreadId"]) == nil else { return nil }
        let status = (value["status"] as? [String: Any])?["type"] as? String
        let phase: SessionPhase
        switch status { case "active": phase = .working; case "notLoaded": phase = .ended; default: phase = .idle }
        let basename = URL(fileURLWithPath: cwd).lastPathComponent
        let project = String((basename.isEmpty ? "Codex" : basename).prefix(128))
        let result = AgentSession(providerID: providerID, nativeID: id, project: project,
            directory: cwd, phase: phase, createdAt: created, updatedAt: updated,
            model: text(value["model"], limit: 256))
        return result.isValid ? result : nil
    }

    static func inputRequest(_ params: [String: Any], id: String) -> AgentInputRequest? {
        guard let questions = params["questions"] as? [[String: Any]], (1...4).contains(questions.count) else { return nil }
        var output: [AgentInputQuestion] = []
        for question in questions {
            guard let questionID = identifier(question["id"]),
                  let prompt = text(question["question"], limit: 4096) else { return nil }
            let options = question["options"] as? [[String: Any]] ?? []
            guard options.count <= 16 else { return nil }
            let labels = options.compactMap { text($0["label"], limit: 512) }
            guard labels.count == options.count else { return nil }
            output.append(AgentInputQuestion(id: questionID,
                title: text(question["header"], limit: 256) ?? "Question", prompt: prompt,
                options: labels, allowsMultiple: false, isSecret: question["isSecret"] as? Bool ?? false))
        }
        let request = AgentInputRequest(id: id, questions: output)
        return request.isValid ? request : nil
    }

    static func usage(_ value: [String: Any], now: Date = Date()) -> AgentUsageSnapshot? {
        // Prefer the ordinary Codex bucket. Specialized model buckets must not
        // become the overall allowance or be summed with the base subscription.
        let buckets = value["rateLimitsByLimitId"] as? [String: [String: Any]]
        guard let bucket = buckets?["codex"] ?? value["rateLimits"] as? [String: Any] else { return nil }
        if let limitID = text(bucket["limitId"], limit: 128), limitID != "codex" { return nil }
        var windows: [AgentQuotaWindow] = []
        for name in ["primary", "secondary"] {
            guard let raw = bucket[name] as? [String: Any],
                  let used = number(raw["usedPercent"]), (0...100).contains(used) else { continue }
            let duration = number(raw["windowDurationMins"])
            let title: String
            switch duration {
            case 300: title = "5 hours"
            case 10_080: title = "Weekly"
            case .some(let minutes) where minutes > 0 && minutes < 525_600:
                title = minutes.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(minutes / 60)) hours" : "\(Int(minutes)) minutes"
            default: title = name == "primary" ? "Primary limit" : "Secondary limit"
            }
            let reset = number(raw["resetsAt"]).flatMap { $0 > 0 ? $0 : nil }
            windows.append(AgentQuotaWindow(id: name, title: title, remainingPercent: 100 - used, resetsAt: reset))
        }
        guard !windows.isEmpty else { return nil }
        return AgentUsageSnapshot(updatedAt: now.timeIntervalSince1970,
            planName: text(bucket["planType"], limit: 128), windows: windows)
    }
}
