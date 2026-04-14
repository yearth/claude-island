//
//  ZellijController.swift
//  ClaudeIsland
//
//  Focus zellij panes and activate the terminal window for a Claude session.
//

import AppKit
import Foundation

actor ZellijController {
    static let shared = ZellijController()

    private var cachedPath: String?

    private init() {}

    // MARK: - Public API

    /// Send a message to the zellij pane running the given Claude PID.
    /// Uses write-chars for text, then send-keys Enter to submit.
    func sendMessage(_ text: String, toClaudePid claudePid: Int) async -> Bool {
        guard let zellijPath = getZellijPath() else { return false }
        guard let info = readZellijPaneInfo(forPid: claudePid) else { return false }
        let paneIdStr = String(info.paneId)
        let sessionName = info.sessionName

        do {
            _ = try await ProcessExecutor.shared.run(
                zellijPath,
                arguments: ["--session", sessionName, "action", "write-chars", "--pane-id", paneIdStr, text]
            )
            _ = try await ProcessExecutor.shared.run(
                zellijPath,
                arguments: ["--session", sessionName, "action", "send-keys", "--pane-id", paneIdStr, "Enter"]
            )
            return true
        } catch {
            return false
        }
    }

    func focusPane(forClaudePid claudePid: Int) async -> Bool {
        guard let zellijPath = getZellijPath() else { return false }
        guard let sessionName = readZellijPaneInfo(forPid: claudePid)?.sessionName else { return false }
        let cwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPid: claudePid)
        let tabName = cwd.flatMap { findTabName(forCwd: $0, sessionName: sessionName, zellijPath: zellijPath) }
        return await switchToTab(sessionName, tabName: tabName, zellijPath: zellijPath)
    }

    func focusPane(forWorkingDirectory cwd: String) async -> Bool {
        guard let zellijPath = getZellijPath() else { return false }
        let tree = ProcessTreeBuilder.shared.buildTree()

        for zellijPid in tree.values.filter({ $0.command.lowercased().contains("zellij") }).map({ $0.pid }) {
            for pid in ProcessTreeBuilder.shared.findDescendants(of: zellijPid, tree: tree) {
                guard let sessionName = readZellijPaneInfo(forPid: pid)?.sessionName,
                      let processCwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPid: pid),
                      processCwd == cwd else { continue }
                let tabName = findTabName(forCwd: cwd, sessionName: sessionName, zellijPath: zellijPath)
                return await switchToTab(sessionName, tabName: tabName, zellijPath: zellijPath)
            }
        }
        return false
    }

    // MARK: - Path

    func getZellijPath() -> String? {
        if let cached = cachedPath { return cached }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.cargo/bin/zellij",
            "/opt/homebrew/bin/zellij",
            "/usr/local/bin/zellij",
            "/usr/bin/zellij",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            cachedPath = found
            return found
        }
        return nil
    }

    // MARK: - Pane Info

    private struct ZellijPaneInfo {
        let paneId: Int
        let sessionName: String
    }

    /// Read ZELLIJ_PANE_ID and ZELLIJ_SESSION_NAME for the pane containing the given PID.
    /// Uses a single `ps eww -ax` call and walks the process tree to find an ancestor with both values.
    private nonisolated func readZellijPaneInfo(forPid targetPid: Int) -> ZellijPaneInfo? {
        guard let output = ProcessExecutor.shared.runSyncOrNil(
            "/bin/ps", arguments: ["eww", "-ax"]
        ) else { return nil }

        var paneIdByPid: [Int: Int] = [:]
        var sessionNameByPid: [Int: String] = [:]
        for line in output.components(separatedBy: "\n") {
            guard line.contains("ZELLIJ_PANE_ID=") || line.contains("ZELLIJ_SESSION_NAME=") else { continue }
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let pid = tokens.first.flatMap({ Int($0) }) else { continue }
            for token in tokens {
                let s = String(token)
                if s.hasPrefix("ZELLIJ_PANE_ID="), let id = Int(s.dropFirst("ZELLIJ_PANE_ID=".count)) {
                    paneIdByPid[pid] = id
                } else if s.hasPrefix("ZELLIJ_SESSION_NAME=") {
                    sessionNameByPid[pid] = String(s.dropFirst("ZELLIJ_SESSION_NAME=".count))
                }
            }
        }

        let tree = ProcessTreeBuilder.shared.buildTree()
        var current = targetPid
        var depth = 0
        while current > 1 && depth < 20 {
            if let paneId = paneIdByPid[current], let sessionName = sessionNameByPid[current] {
                return ZellijPaneInfo(paneId: paneId, sessionName: sessionName)
            }
            guard let info = tree[current] else { break }
            current = info.ppid
            depth += 1
        }
        return nil
    }

    // MARK: - Tab Discovery

    /// Find the tab name in `dump-layout` whose pane cwd matches `targetCwd`.
    private nonisolated func findTabName(forCwd targetCwd: String, sessionName: String, zellijPath: String) -> String? {
        guard let layout = ProcessExecutor.shared.runSyncOrNil(
            zellijPath, arguments: ["--session", sessionName, "action", "dump-layout"]
        ) else { return nil }
        return parseTabContaining(cwd: targetCwd, fromLayout: layout)
    }

    /// Single-pass KDL layout parser.
    ///
    /// Layout structure (relevant lines):
    ///   layout {
    ///     cwd "/absolute/base"          ← least-indented cwd line is the base
    ///     tab name="foo" { ... }
    ///       pane cwd="relative/path"    ← relative to base
    ///   }
    private nonisolated func parseTabContaining(cwd targetCwd: String, fromLayout layout: String) -> String? {
        var baseCwd = ""
        var baseCwdIndent = Int.max
        var currentTab: String? = nil

        for line in layout.components(separatedBy: "\n") {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("cwd \"") && indent < baseCwdIndent {
                baseCwdIndent = indent
                baseCwd = extractKDLString(from: trimmed, after: "cwd ")
            } else if trimmed.hasPrefix("tab ") {
                currentTab = extractKDLStringAttr(key: "name", from: trimmed)
            } else if trimmed.hasPrefix("pane "), let paneCwd = extractKDLStringAttr(key: "cwd", from: trimmed) {
                let absolute = paneCwd.hasPrefix("/") ? paneCwd : "\(baseCwd)/\(paneCwd)"
                if absolute == targetCwd, let tab = currentTab { return tab }
            }
        }
        return nil
    }

    /// Extract a quoted string value: `key="value"` → `"value"`.
    private nonisolated func extractKDLStringAttr(key: String, from line: String) -> String? {
        guard let range = line.range(of: "\(key)=\"", options: .literal) else { return nil }
        let after = line[range.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return nil }
        return String(after[..<end])
    }

    /// Extract a bare quoted string: `prefix "value"` → `"value"`.
    private nonisolated func extractKDLString(from line: String, after prefix: String) -> String {
        let trimmed = line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line
        return trimmed.trimmingCharacters(in: .init(charactersIn: "\" "))
            .components(separatedBy: "\"").first ?? ""
    }

    // MARK: - Focus

    private func switchToTab(_ sessionName: String, tabName: String?, zellijPath: String) async -> Bool {
        if let tab = tabName {
            _ = try? await ProcessExecutor.shared.run(
                zellijPath,
                arguments: ["--session", sessionName, "action", "go-to-tab-name", tab]
            )
        }
        return activateTerminalWindow()
    }

    @discardableResult
    private nonisolated func activateTerminalWindow() -> Bool {
        for bundleId in TerminalAppRegistry.bundleIdentifiers {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                app.activate(options: .activateIgnoringOtherApps)
                return true
            }
        }
        return false
    }
}
