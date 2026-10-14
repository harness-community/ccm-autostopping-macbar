import AppKit
import Foundation
import Security

// MARK: - Settings storage

// API key goes in the Keychain (it's a secret); URL is harmless so plain UserDefaults is fine.
enum SettingsStore {
    private static let urlDefaultsKey = "harnessURL"
    private static let keychainService = "ccm-autostopping-macbar.apiKey"

    static func url() -> String? { UserDefaults.standard.string(forKey: urlDefaultsKey) }
    static func save(url: String) { UserDefaults.standard.set(url, forKey: urlDefaultsKey) }

    static func apiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(apiKey: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService]
        SecItemDelete(query as CFDictionary) // overwrite any previous value
        var attributes = query
        attributes[kSecValueData as String] = Data(apiKey.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

// Pin list + show-all/pinned-only toggle. Not secret, plain UserDefaults is fine.
enum ViewPreferences {
    private static let pinnedKey = "pinnedRuleIDs"
    private static let showPinnedOnlyKey = "showPinnedOnly"

    static func pinnedIDs() -> Set<Int> {
        Set((UserDefaults.standard.array(forKey: pinnedKey) as? [Int]) ?? [])
    }

    static func save(pinnedIDs: Set<Int>) {
        UserDefaults.standard.set(Array(pinnedIDs), forKey: pinnedKey)
    }

    static func showPinnedOnly() -> Bool { UserDefaults.standard.bool(forKey: showPinnedOnlyKey) }
    static func save(showPinnedOnly: Bool) { UserDefaults.standard.set(showPinnedOnly, forKey: showPinnedOnlyKey) }
}

// MARK: - Harness API client

struct HarnessConfig {
    let baseURL: String
    let accountID: String
    let apiKey: String

    // Harness PATs are formatted "pat.<accountId>.<keyId>.<secret>" — the account ID doesn't need
    // to be entered separately, it can be pulled straight out of the key.
    static func accountID(fromAPIKey apiKey: String) -> String? {
        let parts = apiKey.split(separator: ".")
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    // Settings saved in-app (Settings window) take priority over environment variables, so a
    // non-technical user's setup always wins over whatever happens to be left in the shell env.
    static func resolve() -> HarnessConfig? {
        let env = ProcessInfo.processInfo.environment
        let apiKey = SettingsStore.apiKey() ?? env["HARNESS_PLATFORM_API_KEY"] ?? env["HARNESS_API_KEY"] ?? ""
        guard !apiKey.isEmpty else { return nil }
        let explicitAccountID = env["HARNESS_ACCOUNT_ID"]
        guard let accountID = (explicitAccountID?.isEmpty == false ? explicitAccountID : nil) ?? accountID(fromAPIKey: apiKey) else {
            return nil
        }
        let baseURL = SettingsStore.url() ?? (env["HARNESS_URL"]?.isEmpty == false ? env["HARNESS_URL"]! : "https://app.harness.io")
        return HarnessConfig(baseURL: baseURL, accountID: accountID, apiKey: apiKey)
    }
}

struct RuleRaw: Decodable {
    let id: Int
    let name: String
    let kind: String
    let disabled: Bool
}

private struct ListResponse: Decodable { let response: [RuleRaw]? }
private struct HealthResponse: Decodable { let response: HealthState? }
private struct HealthState: Decodable { let state: String? }

enum HarnessError: Error, CustomStringConvertible {
    case http(Int, String)
    var description: String {
        switch self {
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        }
    }
}

final class HarnessClient {
    let config: HarnessConfig
    private let session = URLSession.shared

    init(config: HarnessConfig) { self.config = config }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        var urlString = "\(config.baseURL)/gateway/lw/api/accounts/\(config.accountID)/autostopping\(path)"
        urlString += urlString.contains("?") ? "&accountIdentifier=\(config.accountID)" : "?accountIdentifier=\(config.accountID)"
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = method
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw HarnessError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    func listRules() async throws -> [RuleRaw] {
        let data = try await request("/rules")
        return try JSONDecoder().decode(ListResponse.self, from: data).response ?? []
    }

    func health(ruleID: Int) async throws -> String {
        let data = try await request("/rules/\(ruleID)/health")
        return try JSONDecoder().decode(HealthResponse.self, from: data).response?.state ?? "unknown"
    }

    func warmup(ruleID: Int) async throws {
        _ = try await request("/rules/\(ruleID)/warmup", method: "POST", body: ["forced_trigger": true])
    }

    func cooldown(ruleID: Int) async throws {
        _ = try await request("/rules/\(ruleID)/cooldown", method: "POST", body: ["force": true])
    }
}

// MARK: - UI model

struct RuleRow {
    let id: Int
    let name: String
    let disabled: Bool
    var state: String // "active" | "down" | "warmingup" | "coolingdown" | "unknown" | "loading"
    var pinned: Bool

    var color: NSColor {
        switch state {
        case "active": return .systemGreen
        case "down": return .secondaryLabelColor
        case "warmingup", "coolingdown": return .systemOrange
        default: return .tertiaryLabelColor
        }
    }

    var label: String {
        switch state {
        case "active": return "Running"
        case "down": return "Stopped"
        case "warmingup": return "Starting…"
        case "coolingdown": return "Stopping…"
        case "loading": return "Checking…"
        default: return "Unknown"
        }
    }

    // Only offer the action that makes sense for the current state.
    var actionTitle: String? {
        switch state {
        case "down": return "Start"
        case "active": return "Stop"
        default: return nil // mid-transition or unknown: no action until it settles
        }
    }

    // What state we're waiting for after pressing the action above.
    var targetState: String? {
        switch actionTitle {
        case "Start": return "active"
        case "Stop": return "down"
        default: return nil
        }
    }
}

// MARK: - Menu styling helpers

private enum Style {
    static let title = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                         .foregroundColor: NSColor.labelColor]
    static let subtitle = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 11),
                            .foregroundColor: NSColor.secondaryLabelColor]
    static let name = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 13, weight: .bold),
                        .foregroundColor: NSColor.labelColor]
    static let disabledTag = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 11),
                               .foregroundColor: NSColor.tertiaryLabelColor]
    static let error = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                         .foregroundColor: NSColor.systemRed]

    static func rowTitle(_ row: RuleRow) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "●  ", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: row.color])
        result.append(NSAttributedString(string: row.name, attributes: name))
        if row.disabled {
            result.append(NSAttributedString(string: "  disabled", attributes: disabledTag))
        }
        result.append(NSAttributedString(string: "   \(row.label)", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: row.color]))
        return result
    }

    static func actionTitle(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: color])
    }

    static func symbol(_ name: String, color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [color]))
    }

    static func pinSymbol(pinned: Bool) -> NSImage? {
        symbol(pinned ? "pin.fill" : "pin", color: pinned ? .systemYellow : .tertiaryLabelColor)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var client: HarnessClient?
    private var rows: [RuleRow] = []
    private var errorMessage: String?
    private var lastCheckedAt: Date?
    private var pollingRuleIDs: Set<Int> = []
    private let refreshIntervalSeconds: TimeInterval = 30
    private var pinnedRuleIDs: Set<Int> = ViewPreferences.pinnedIDs()
    private var showPinnedOnly: Bool = ViewPreferences.showPinnedOnly()

    private var settingsWindow: NSWindow?
    private let urlField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let settingsStatusLabel = NSTextField(wrappingLabelWithString: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "powerplug.fill", accessibilityDescription: "CCM AutoStopping")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.menu = NSMenu()

        if let config = HarnessConfig.resolve() {
            client = HarnessClient(config: config)
        } else {
            errorMessage = "Not configured — open Settings to add your Harness URL and API key"
        }

        rebuildMenu()
        if client == nil { openSettings() } // first run / nothing configured yet: don't make them hunt for the menu item
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: refreshIntervalSeconds, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    @MainActor
    private func refresh() async {
        guard let client else { rebuildMenu(); return }
        do {
            let rules = try await client.listRules()
            let healthByID: [Int: String] = await withTaskGroup(of: (Int, String).self) { group in
                for rule in rules {
                    group.addTask {
                        let state = try? await client.health(ruleID: rule.id)
                        return (rule.id, state ?? "unknown")
                    }
                }
                var result: [Int: String] = [:]
                for await (id, state) in group { result[id] = state }
                return result
            }
            let existingByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            rows = rules
                .sorted { $0.name < $1.name }
                .map { rule in
                    // A targeted post-action poll owns this row right now; don't fight it with a stale/racy fetch.
                    if pollingRuleIDs.contains(rule.id), let existing = existingByID[rule.id] {
                        return existing
                    }
                    return RuleRow(id: rule.id, name: rule.name, disabled: rule.disabled, state: healthByID[rule.id] ?? "unknown", pinned: pinnedRuleIDs.contains(rule.id))
                }
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
        lastCheckedAt = Date()
        rebuildMenu()
    }

    @MainActor
    private func rebuildMenu() {
        let menu = NSMenu()

        let title = NSMenuItem()
        title.attributedTitle = NSAttributedString(string: "CCM AutoStopping Rules", attributes: Style.title)
        title.isEnabled = false
        menu.addItem(title)

        if let errorMessage {
            let item = NSMenuItem()
            item.attributedTitle = NSAttributedString(string: "⚠ \(errorMessage)", attributes: Style.error)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let modeItem = NSMenuItem(title: "", action: #selector(toggleModeTapped), keyEquivalent: "")
        modeItem.attributedTitle = NSAttributedString(string: "Show Only Pinned", attributes: Style.name)
        modeItem.state = showPinnedOnly ? .on : .off
        modeItem.target = self
        menu.addItem(modeItem)
        menu.addItem(.separator())

        if rows.isEmpty, errorMessage == nil {
            menu.addItem(withTitle: "Loading rules…", action: nil, keyEquivalent: "")
        }

        let pinnedRows = rows.filter { $0.pinned }
        let unpinnedRows = rows.filter { !$0.pinned }

        if showPinnedOnly {
            if pinnedRows.isEmpty, !rows.isEmpty {
                menu.addItem(withTitle: "No pinned rules yet — pin some from \"All Rules\" below", action: nil, keyEquivalent: "")
            }
            for row in pinnedRows { addRuleItems(row, to: menu) }

            menu.addItem(.separator())
            let allItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            allItem.attributedTitle = NSAttributedString(string: "All Rules (\(unpinnedRows.count))", attributes: Style.name)
            allItem.image = Style.symbol("list.bullet", color: .secondaryLabelColor)
            let submenu = NSMenu()
            if unpinnedRows.isEmpty {
                submenu.addItem(withTitle: rows.isEmpty ? "Loading…" : "Everything is pinned", action: nil, keyEquivalent: "")
            } else {
                for row in unpinnedRows { addRuleItems(row, to: submenu) }
            }
            allItem.submenu = submenu
            menu.addItem(allItem)
        } else {
            for row in pinnedRows + unpinnedRows { addRuleItems(row, to: menu) }
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "", action: #selector(refreshTapped), keyEquivalent: "r")
        refreshItem.attributedTitle = NSAttributedString(string: "Refresh Now", attributes: Style.name)
        refreshItem.image = Style.symbol("arrow.clockwise", color: .secondaryLabelColor)
        refreshItem.target = self
        menu.addItem(refreshItem)

        let lastCheckedText = lastCheckedAt.map { "Last checked \(DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium))" } ?? "Not checked yet"
        let lastChecked = NSMenuItem()
        lastChecked.attributedTitle = NSAttributedString(string: lastCheckedText, attributes: Style.subtitle)
        lastChecked.isEnabled = false
        menu.addItem(lastChecked)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.attributedTitle = NSAttributedString(string: "Settings…", attributes: Style.name)
        settingsItem.image = Style.symbol("gearshape", color: .secondaryLabelColor)
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    /// Adds a rule's header (name/status, click to pin/unpin) and its Start/Stop action, if any,
    /// to the given menu. Shared between the top-level menu and the "All Rules" submenu so pinning
    /// works the same way from either place.
    @MainActor
    private func addRuleItems(_ row: RuleRow, to menu: NSMenu) {
        let header = NSMenuItem(title: "", action: #selector(pinTapped(_:)), keyEquivalent: "")
        header.attributedTitle = Style.rowTitle(row)
        header.image = Style.pinSymbol(pinned: row.pinned)
        header.target = self
        header.tag = row.id
        header.toolTip = row.pinned ? "Click to unpin" : "Click to pin to the top"
        menu.addItem(header)

        if let actionTitle = row.actionTitle {
            let isStart = actionTitle == "Start"
            let color: NSColor = isStart ? .systemGreen : .systemRed
            let item = NSMenuItem(title: "", action: #selector(startStopTapped(_:)), keyEquivalent: "")
            item.attributedTitle = Style.actionTitle("    \(actionTitle)", color: color)
            item.image = Style.symbol(isStart ? "play.fill" : "stop.fill", color: color)
            item.target = self
            item.tag = row.id
            item.representedObject = actionTitle
            menu.addItem(item)
        }
    }

    @MainActor @objc private func toggleModeTapped() {
        showPinnedOnly.toggle()
        ViewPreferences.save(showPinnedOnly: showPinnedOnly)
        rebuildMenu()
    }

    @MainActor @objc private func pinTapped(_ sender: NSMenuItem) {
        let ruleID = sender.tag
        if pinnedRuleIDs.contains(ruleID) {
            pinnedRuleIDs.remove(ruleID)
        } else {
            pinnedRuleIDs.insert(ruleID)
        }
        ViewPreferences.save(pinnedIDs: pinnedRuleIDs)
        if let idx = rows.firstIndex(where: { $0.id == ruleID }) {
            rows[idx].pinned = pinnedRuleIDs.contains(ruleID)
        }
        rebuildMenu()
    }

    @objc private func refreshTapped() {
        Task { await refresh() }
    }

    @MainActor @objc private func startStopTapped(_ sender: NSMenuItem) {
        guard let client, let action = sender.representedObject as? String else { return }
        let ruleID = sender.tag
        guard let idx = rows.firstIndex(where: { $0.id == ruleID }) else { return }

        let target = action == "Start" ? "active" : "down"
        rows[idx].state = action == "Start" ? "warmingup" : "coolingdown"
        rebuildMenu()

        Task {
            do {
                if action == "Start" {
                    try await client.warmup(ruleID: ruleID)
                } else {
                    try await client.cooldown(ruleID: ruleID)
                }
            } catch {
                errorMessage = "\(action) failed for \(rows[idx].name): \(error)"
                rebuildMenu()
                return
            }
            await pollUntilSettled(ruleID: ruleID, target: target)
            await refresh() // resync the full list (and "last checked") now that this rule has settled
        }
    }

    /// Polls just this one rule's health every couple seconds, pushing each state change straight
    /// into the menu, so the user sees "Starting… -> Running" live instead of waiting for the next
    /// 30s background refresh.
    @MainActor
    private func pollUntilSettled(ruleID: Int, target: String) async {
        guard let client else { return }
        pollingRuleIDs.insert(ruleID)
        defer { pollingRuleIDs.remove(ruleID) }

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let state = (try? await client.health(ruleID: ruleID)) ?? "unknown"
            if let idx = rows.firstIndex(where: { $0.id == ruleID }) {
                rows[idx].state = state
            }
            rebuildMenu()
            if state == target { return }
        }
    }

    // MARK: Settings window

    @MainActor @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = buildSettingsWindow() }
        urlField.stringValue = SettingsStore.url() ?? "https://app.harness.io"
        apiKeyField.stringValue = SettingsStore.apiKey() ?? ""
        settingsStatusLabel.stringValue = ""
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func buildSettingsWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 230),
                               styleMask: [.titled, .closable],
                               backing: .buffered, defer: false)
        window.title = "CCM AutoStopping Settings"
        window.isReleasedWhenClosed = false

        func labeled(_ text: String, _ field: NSView) -> NSStackView {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            let row = NSStackView(views: [label, field])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 4
            return row
        }

        urlField.placeholderString = "https://app.harness.io"
        apiKeyField.placeholderString = "pat.xxxxxxxx.xxxxxxxx.xxxxxxxxxxxxxxxxxxxxxxxx"
        for field in [urlField, apiKeyField] {
            field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }

        settingsStatusLabel.textColor = .systemRed
        settingsStatusLabel.font = .systemFont(ofSize: 11)
        settingsStatusLabel.isEditable = false
        settingsStatusLabel.isBordered = false
        settingsStatusLabel.drawsBackground = false
        settingsStatusLabel.widthAnchor.constraint(equalToConstant: 360).isActive = true

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelSettingsTapped))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettingsTapped))
        saveButton.keyEquivalent = "\r" // Return triggers Save
        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let hint = NSTextField(wrappingLabelWithString: "Your account ID is read automatically from the API key — you don't need to enter it separately.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: 360).isActive = true

        let stack = NSStackView(views: [
            labeled("Harness URL", urlField),
            labeled("API Key", apiKeyField),
            hint,
            settingsStatusLabel,
            buttonRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        return window
    }

    @objc private func cancelSettingsTapped() {
        settingsWindow?.close()
    }

    @MainActor @objc private func saveSettingsTapped() {
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !key.isEmpty else {
            settingsStatusLabel.stringValue = "API key is required."
            return
        }
        guard HarnessConfig.accountID(fromAPIKey: key) != nil else {
            settingsStatusLabel.stringValue = "That doesn't look like a Harness API key (expected format: pat.<account>.<id>.<secret>)."
            return
        }

        SettingsStore.save(url: url.isEmpty ? "https://app.harness.io" : url)
        SettingsStore.save(apiKey: key)
        settingsWindow?.close()

        guard let config = HarnessConfig.resolve() else { return } // can't happen, we just validated above
        client = HarnessClient(config: config)
        errorMessage = nil
        Task { await refresh() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
