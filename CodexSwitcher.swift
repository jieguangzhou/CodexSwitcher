import AppKit
import Foundation

// MARK: - Data Models

struct CodexAccount {
    let alias: String
    let email: String
    let plan: String
    let authMode: String
    let accountId: String
    let subscriptionStart: String?
    let subscriptionUntil: String?
    let daysRemaining: Int?
    let tokenExpiry: Date?
}

struct RateLimitWindow {
    let usedPercent: Int
    let windowDurationMins: Int
    let resetsAt: Date?
}

struct CreditsSnapshot {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

struct RateLimitInfo {
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?
    let planType: String?
}

// MARK: - Auth Manager

class CodexAuthManager {
    static let shared = CodexAuthManager()

    private let codexDir: String
    let authFile: String
    private let currentFile: String
    private let accountsDir: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        codexDir = "\(home)/.codex"
        authFile = "\(codexDir)/auth.json"
        currentFile = "\(codexDir)/current"
        accountsDir = "\(codexDir)/accounts"
    }

    func currentAlias() -> String {
        guard let data = try? String(contentsOfFile: currentFile, encoding: .utf8) else { return "?" }
        return data.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func listAccounts() -> [CodexAccount] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: accountsDir) else { return [] }
        return files
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .compactMap { file -> CodexAccount? in
                let alias = String(file.dropLast(5))
                let path = "\(accountsDir)/\(file)"
                return parseAccountFile(path, alias: alias)
            }
    }

    func switchTo(alias: String) -> Bool {
        let current = currentAlias()
        let targetFile = "\(accountsDir)/\(alias).json"
        guard FileManager.default.fileExists(atPath: targetFile) else { return false }
        if !current.isEmpty && current != "?" && FileManager.default.fileExists(atPath: authFile) {
            let currentAccountFile = "\(accountsDir)/\(current).json"
            try? FileManager.default.removeItem(atPath: currentAccountFile)
            try? FileManager.default.copyItem(atPath: authFile, toPath: currentAccountFile)
        }
        do {
            try FileManager.default.removeItem(atPath: authFile)
            try FileManager.default.copyItem(atPath: targetFile, toPath: authFile)
            try alias.write(toFile: currentFile, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    func parseAccountFile(_ path: String, alias: String) -> CodexAccount? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let authMode = json["auth_mode"] as? String ?? "chatgpt"
        let tokens = json["tokens"] as? [String: Any] ?? [:]
        let accountId = tokens["account_id"] as? String ?? "?"
        var email = "?"; var plan = "?"
        var subStart: String?; var subUntil: String?
        var daysRemaining: Int?; var tokenExpiry: Date?
        if let idToken = tokens["id_token"] as? String, let payload = decodeJWTPayload(idToken) {
            email = payload["email"] as? String ?? "?"
            if let exp = payload["exp"] as? Double { tokenExpiry = Date(timeIntervalSince1970: exp) }
            if let auth = payload["https://api.openai.com/auth"] as? [String: Any] {
                plan = auth["chatgpt_plan_type"] as? String ?? "?"
                subStart = auth["chatgpt_subscription_active_start"] as? String
                subUntil = auth["chatgpt_subscription_active_until"] as? String
                if let until = subUntil {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let d = f.date(from: until) ?? ISO8601DateFormatter().date(from: until) {
                        daysRemaining = Calendar.current.dateComponents([.day], from: Date(), to: d).day
                    }
                }
            }
        }
        if tokenExpiry == nil, let at = tokens["access_token"] as? String, let p = decodeJWTPayload(at) {
            if let exp = p["exp"] as? Double { tokenExpiry = Date(timeIntervalSince1970: exp) }
        }
        return CodexAccount(alias: alias, email: email, plan: plan, authMode: authMode,
            accountId: accountId, subscriptionStart: subStart, subscriptionUntil: subUntil,
            daysRemaining: daysRemaining, tokenExpiry: tokenExpiry)
    }

    func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let r = b64.count % 4
        if r > 0 { b64 += String(repeating: "=", count: 4 - r) }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }
}

// MARK: - App-Server Rate Limit Client

class RateLimitClient {
    private var serverProcess: Process?
    private let port: Int
    private let codexPath = "/Applications/Codex.app/Contents/Resources/codex"
    var rateLimitInfo: RateLimitInfo?
    var onUpdate: (() -> Void)?

    init() {
        port = Int.random(in: 19000...19999)
    }

    func start() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.launchAndQuery()
        }
    }

    func refresh() {
        // Kill existing server and re-query
        serverProcess?.terminate()
        serverProcess = nil
        rateLimitInfo = nil
        start()
    }

    private func launchAndQuery() {
        guard FileManager.default.fileExists(atPath: codexPath) else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: codexPath)
        proc.arguments = ["app-server", "--listen", "ws://127.0.0.1:\(port)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        serverProcess = proc

        do { try proc.run() } catch { return }

        // Wait for server to be ready
        Thread.sleep(forTimeInterval: 3)
        guard proc.isRunning else { return }

        // Connect via raw socket websocket
        queryRateLimits()

        // Terminate server after query
        proc.terminate()
        serverProcess = nil
    }

    private func queryRateLimits() {
        guard let sock = wsConnect(host: "127.0.0.1", port: port) else { return }
        defer { close(sock) }

        // Initialize
        let initMsg = """
        {"jsonrpc":"2.0","method":"initialize","id":1,"params":{"clientInfo":{"name":"codex-switcher","title":null,"version":"1.0"},"capabilities":null}}
        """
        wsSend(sock, message: initMsg)
        _ = wsRecv(sock, timeout: 5)

        // Rate limits
        wsSend(sock, message: """
        {"jsonrpc":"2.0","method":"account/rateLimits/read","id":2}
        """)

        for _ in 0..<10 {
            guard let resp = wsRecv(sock, timeout: 10) else { break }
            guard let data = try? JSONSerialization.jsonObject(with: Data(resp.utf8)) as? [String: Any] else { continue }
            if let id = data["id"] as? Int, id == 2 {
                if let result = data["result"] as? [String: Any],
                   let rl = result["rateLimits"] as? [String: Any] {
                    self.rateLimitInfo = parseRateLimitSnapshot(rl)
                    DispatchQueue.main.async { self.onUpdate?() }
                }
                break
            }
        }
    }

    private func parseRateLimitSnapshot(_ json: [String: Any]) -> RateLimitInfo {
        let primary = parseWindow(json["primary"])
        let secondary = parseWindow(json["secondary"])
        var credits: CreditsSnapshot? = nil
        if let c = json["credits"] as? [String: Any] {
            credits = CreditsSnapshot(
                hasCredits: c["hasCredits"] as? Bool ?? false,
                unlimited: c["unlimited"] as? Bool ?? false,
                balance: c["balance"] as? String
            )
        }
        return RateLimitInfo(primary: primary, secondary: secondary, credits: credits, planType: json["planType"] as? String)
    }

    private func parseWindow(_ obj: Any?) -> RateLimitWindow? {
        guard let w = obj as? [String: Any] else { return nil }
        let used = w["usedPercent"] as? Int ?? 0
        let dur = w["windowDurationMins"] as? Int ?? 0
        var resetsAt: Date? = nil
        if let ts = w["resetsAt"] as? Double { resetsAt = Date(timeIntervalSince1970: ts) }
        return RateLimitWindow(usedPercent: used, windowDurationMins: dur, resetsAt: resetsAt)
    }

    // MARK: - Raw WebSocket

    private func wsConnect(host: String, port: Int) -> Int32? {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { close(sock); return nil }

        // WebSocket handshake
        var keyBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &keyBytes)
        let key = Data(keyBytes).base64EncodedString()

        let handshake = "GET / HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        _ = handshake.withCString { send(sock, $0, strlen($0), 0) }

        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(sock, &buf, buf.count, 0)
        guard n > 0 else { close(sock); return nil }
        let resp = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
        guard resp.contains("101") else { close(sock); return nil }

        return sock
    }

    private func wsSend(_ sock: Int32, message: String) {
        let data = Array(message.utf8)
        var frame = [UInt8]()
        frame.append(0x81)

        var maskKey = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &maskKey)

        if data.count < 126 {
            frame.append(UInt8(0x80 | data.count))
        } else if data.count < 65536 {
            frame.append(0x80 | 126)
            frame.append(UInt8((data.count >> 8) & 0xFF))
            frame.append(UInt8(data.count & 0xFF))
        } else {
            frame.append(0x80 | 127)
            for i in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((data.count >> i) & 0xFF))
            }
        }
        frame.append(contentsOf: maskKey)
        for (i, byte) in data.enumerated() {
            frame.append(byte ^ maskKey[i % 4])
        }
        frame.withUnsafeBufferPointer { buf in
            _ = send(sock, buf.baseAddress!, buf.count, 0)
        }
    }

    private func wsRecv(_ sock: Int32, timeout: Int = 10) -> String? {
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var header = [UInt8](repeating: 0, count: 2)
        guard recv(sock, &header, 2, MSG_WAITALL) == 2 else { return nil }

        var length = Int(header[1] & 0x7F)
        if length == 126 {
            var ext = [UInt8](repeating: 0, count: 2)
            guard recv(sock, &ext, 2, MSG_WAITALL) == 2 else { return nil }
            length = Int(ext[0]) << 8 | Int(ext[1])
        } else if length == 127 {
            var ext = [UInt8](repeating: 0, count: 8)
            guard recv(sock, &ext, 8, MSG_WAITALL) == 8 else { return nil }
            length = 0
            for b in ext { length = length << 8 | Int(b) }
        }

        var payload = [UInt8](repeating: 0, count: length)
        var received = 0
        while received < length {
            let n = recv(sock, &payload[received], length - received, 0)
            guard n > 0 else { return nil }
            received += n
        }
        return String(bytes: payload, encoding: .utf8)
    }

    deinit {
        serverProcess?.terminate()
    }
}

// MARK: - Menu Bar App

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let authManager = CodexAuthManager.shared
    private var fileMonitor: DispatchSourceFileSystemObject?
    private let rateLimitClient = RateLimitClient()
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rateLimitClient.onUpdate = { [weak self] in self?.updateMenu() }
        updateMenu()
        watchAuthFile()
        rateLimitClient.start()

        // Auto-refresh rate limits every 3 minutes
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            self?.rateLimitClient.refresh()
        }
    }

    private func formatDate(_ isoString: String?) -> String? {
        guard let str = isoString else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: str) ?? ISO8601DateFormatter().date(from: str) else { return nil }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    private func formatResetTime(_ date: Date?) -> String {
        guard let d = date else { return "" }
        let mins = Int(d.timeIntervalSinceNow / 60)
        if mins <= 0 { return "now" }
        if mins < 60 { return "\(mins)m" }
        let hours = mins / 60
        let remMins = mins % 60
        if hours < 24 { return remMins > 0 ? "\(hours)h\(remMins)m" : "\(hours)h" }
        return "\(hours / 24)d\(hours % 24)h"
    }

    private func usageBar(_ percent: Int, width: Int = 15) -> String {
        let filled = Int(Double(percent) / 100.0 * Double(width))
        let empty = width - filled
        return String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: empty)
    }

    private func updateMenu() {
        let current = authManager.currentAlias()
        let accounts = authManager.listAccounts()

        // Status bar
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: "Codex Switcher") {
                let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
                button.image = img.withSymbolConfiguration(config)
                button.imagePosition = .imageOnly
            }
            let currentAccount = accounts.first(where: { $0.alias == current })
            var tip = "Codex: \(currentAccount?.alias ?? current) (\(currentAccount?.plan ?? "?"))"
            if let rl = rateLimitClient.rateLimitInfo {
                let p = rl.primary?.usedPercent ?? 0
                let s = rl.secondary?.usedPercent ?? 0
                tip += "\n5h: \(p)% | Week: \(s)%"
            }
            button.toolTip = tip
        }

        let menu = NSMenu()

        // === Rate Limits Section ===
        if let rl = rateLimitClient.rateLimitInfo {
            let rlHeader = NSMenuItem()
            rlHeader.attributedTitle = NSAttributedString(string: "USAGE", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .kern: 1.5
            ])
            rlHeader.isEnabled = false
            menu.addItem(rlHeader)

            // 5-hour window
            if let p = rl.primary {
                let item = NSMenuItem()
                let title = NSMutableAttributedString()
                let remaining = 100 - p.usedPercent
                let color: NSColor = remaining <= 10 ? .systemRed : remaining <= 25 ? .systemOrange : .secondaryLabelColor

                title.append(NSAttributedString(string: "  5h   ", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.labelColor
                ]))
                title.append(NSAttributedString(string: usageBar(p.usedPercent), attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: color
                ]))
                title.append(NSAttributedString(string: "  \(remaining)% left", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: color
                ]))
                if p.resetsAt != nil {
                    title.append(NSAttributedString(string: "  \u{21BB}\(formatResetTime(p.resetsAt))", attributes: [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.tertiaryLabelColor
                    ]))
                }
                item.attributedTitle = title
                item.isEnabled = false
                menu.addItem(item)
            }

            // Weekly window
            if let s = rl.secondary {
                let item = NSMenuItem()
                let title = NSMutableAttributedString()
                let remaining = 100 - s.usedPercent
                let color: NSColor = remaining <= 10 ? .systemRed : remaining <= 25 ? .systemOrange : .secondaryLabelColor

                title.append(NSAttributedString(string: "  Week ", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.labelColor
                ]))
                title.append(NSAttributedString(string: usageBar(s.usedPercent), attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: color
                ]))
                title.append(NSAttributedString(string: "  \(remaining)% left", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: color
                ]))
                if s.resetsAt != nil {
                    title.append(NSAttributedString(string: "  \u{21BB}\(formatResetTime(s.resetsAt))", attributes: [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.tertiaryLabelColor
                    ]))
                }
                item.attributedTitle = title
                item.isEnabled = false
                menu.addItem(item)
            }

            // Credits
            if let credits = rl.credits {
                let item = NSMenuItem()
                let title = NSMutableAttributedString()
                let creditText: String
                if credits.unlimited {
                    creditText = "  Credits: Unlimited"
                } else if let bal = credits.balance, !bal.isEmpty {
                    creditText = "  Credits: \(bal)"
                } else if credits.hasCredits {
                    creditText = "  Credits: Available"
                } else {
                    creditText = "  Credits: None"
                }
                title.append(NSAttributedString(string: creditText, attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: credits.hasCredits || credits.unlimited ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
                ]))
                item.attributedTitle = title
                item.isEnabled = false
                menu.addItem(item)
            }

            menu.addItem(NSMenuItem.separator())
        } else {
            // Loading state
            let loadingItem = NSMenuItem()
            loadingItem.attributedTitle = NSAttributedString(string: "  Loading usage...", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor
            ])
            loadingItem.isEnabled = false
            menu.addItem(loadingItem)
            menu.addItem(NSMenuItem.separator())
        }

        // === Accounts Section ===
        let acctHeader = NSMenuItem()
        acctHeader.attributedTitle = NSAttributedString(string: "ACCOUNTS", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 1.5
        ])
        acctHeader.isEnabled = false
        menu.addItem(acctHeader)
        menu.addItem(NSMenuItem.separator())

        for account in accounts {
            let isActive = account.alias == current
            let item = NSMenuItem()
            item.representedObject = account.alias
            let title = NSMutableAttributedString()

            let check = isActive ? "\u{2713} " : "     "
            title.append(NSAttributedString(string: check, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: isActive ? NSColor.systemGreen : NSColor.clear
            ]))
            title.append(NSAttributedString(string: account.alias, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: isActive ? .semibold : .regular)
            ]))
            let planColor: NSColor
            switch account.plan {
            case "team": planColor = .systemBlue
            case "pro": planColor = .systemPurple
            case "plus": planColor = .systemGreen
            default: planColor = .systemGray
            }
            title.append(NSAttributedString(string: "  \(account.plan.uppercased())", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: planColor,
                .baselineOffset: 2
            ]))

            title.append(NSAttributedString(string: "\n     \(account.email)", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))

            // Subscription info
            var subLine = ""
            if let days = account.daysRemaining, let until = formatDate(account.subscriptionUntil) {
                if days < 0 { subLine = "     \u{26A0} Expired" }
                else { subLine = "     \u{23F3} \(days)d left \u{2192} \(until)" }
            }
            var tokenWarning = ""
            if let exp = account.tokenExpiry, exp < Date() { tokenWarning = "  \u{1F534} Token expired" }

            if !subLine.isEmpty || !tokenWarning.isEmpty {
                let subColor: NSColor
                if account.daysRemaining != nil && account.daysRemaining! < 0 { subColor = .systemRed }
                else if account.daysRemaining != nil && account.daysRemaining! <= 7 { subColor = .systemOrange }
                else if account.tokenExpiry != nil && account.tokenExpiry! < Date() { subColor = .systemRed }
                else { subColor = .tertiaryLabelColor }
                title.append(NSAttributedString(string: "\n\(subLine)\(tokenWarning)", attributes: [
                    .font: NSFont.systemFont(ofSize: 10), .foregroundColor: subColor
                ]))
            }

            item.attributedTitle = title
            item.target = self
            item.action = isActive ? nil : #selector(switchAccount(_:))
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let loginItem = NSMenuItem(title: "Login New Account...", action: #selector(loginNewAccount), keyEquivalent: "l")
        loginItem.target = self
        menu.addItem(loginItem)

        let refreshItem = NSMenuItem(title: "Refresh Usage", action: #selector(refreshUsage), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let alias = sender.representedObject as? String else { return }
        if authManager.switchTo(alias: alias) {
            updateMenu()
            // Re-fetch rate limits for new account
            rateLimitClient.refresh()
            let n = NSUserNotification()
            n.title = "Codex Account Switched"
            n.informativeText = "Now using: \(alias)"
            NSUserNotificationCenter.default.deliver(n)
        } else {
            let a = NSAlert()
            a.messageText = "Switch Failed"
            a.informativeText = "Could not switch to '\(alias)'"
            a.alertStyle = .warning
            a.runModal()
        }
    }

    @objc private func loginNewAccount() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Terminal", "/Applications/Codex.app/Contents/Resources/codex", "--args", "login"]
        try? task.run()
    }

    @objc private func refreshUsage() {
        rateLimitClient.rateLimitInfo = nil
        updateMenu()
        rateLimitClient.refresh()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func watchAuthFile() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.updateMenu() }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileMonitor = source
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
