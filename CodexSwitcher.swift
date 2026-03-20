import AppKit
import Foundation
import UserNotifications
import ServiceManagement

// MARK: - Data Models

struct CodexAccount {
    let alias: String
    let email: String
    let plan: String
    let authMode: String
    let accountId: String
    let accessToken: String
    let subscriptionStart: String?
    let subscriptionUntil: String?
    let daysRemaining: Int?
    let tokenExpiry: Date?

    var isTokenExpired: Bool {
        guard let exp = tokenExpiry else { return false }
        return exp < Date()
    }

    var planColor: NSColor {
        switch plan {
        case "team": return NSColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0)
        case "pro": return NSColor(red: 0.6, green: 0.35, blue: 0.9, alpha: 1.0)
        case "plus": return NSColor(red: 0.2, green: 0.75, blue: 0.5, alpha: 1.0)
        default: return .secondaryLabelColor
        }
    }

    var planLabel: String { plan.uppercased() }
}

struct RateLimitWindow {
    let usedPercent: Int
    let resetsAt: Date?

    var remaining: Int { 100 - min(max(usedPercent, 0), 100) }

    var barColor: NSColor {
        if remaining <= 10 { return NSColor(red: 0.95, green: 0.3, blue: 0.3, alpha: 1.0) }
        if remaining <= 25 { return NSColor(red: 0.95, green: 0.6, blue: 0.2, alpha: 1.0) }
        if remaining <= 50 { return NSColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1.0) }
        if remaining <= 75 { return NSColor(red: 0.3, green: 0.78, blue: 0.5, alpha: 1.0) }
        return NSColor(red: 0.25, green: 0.72, blue: 0.45, alpha: 1.0)
    }

    var textColor: NSColor {
        if remaining <= 10 { return NSColor(red: 0.9, green: 0.25, blue: 0.25, alpha: 1.0) }
        if remaining <= 25 { return NSColor(red: 0.85, green: 0.5, blue: 0.15, alpha: 1.0) }
        return NSColor.secondaryLabelColor
    }
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

enum FetchState {
    case idle
    case loading
    case success(RateLimitInfo)
    case failed(String)
}

// MARK: - Config

struct AppConfig {
    var refreshIntervalMinutes: Int = 30
    var minRefreshIntervalSeconds: Int = 30
    var alert5hThreshold: Int = 30    // alert when 5h remaining < this %
    var alertWeekThreshold: Int = 10  // alert when week remaining < this %

    private static let configPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.codex/switcher.json"
    }()

    static func load() -> AppConfig {
        var config = AppConfig()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return config }
        if let v = json["refresh_interval_minutes"] as? Int, v > 0 { config.refreshIntervalMinutes = v }
        if let v = json["min_refresh_interval_seconds"] as? Int, v > 0 { config.minRefreshIntervalSeconds = v }
        if let v = json["alert_5h_threshold"] as? Int { config.alert5hThreshold = v }
        if let v = json["alert_week_threshold"] as? Int { config.alertWeekThreshold = v }
        return config
    }

    func save() {
        let json: [String: Any] = [
            "refresh_interval_minutes": refreshIntervalMinutes,
            "min_refresh_interval_seconds": minRefreshIntervalSeconds,
            "alert_5h_threshold": alert5hThreshold,
            "alert_week_threshold": alertWeekThreshold
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: AppConfig.configPath))
        }
    }
}

// MARK: - Auth Manager

class CodexAuthManager {
    static let shared = CodexAuthManager()

    private let codexDir: String
    let authFile: String
    private let currentFile: String
    let accountsDir: String

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
                return parseAccountFile("\(accountsDir)/\(file)", alias: alias)
            }
    }

    func switchTo(alias: String) -> Bool {
        let fm = FileManager.default
        let current = currentAlias()
        let targetFile = "\(accountsDir)/\(alias).json"
        guard fm.fileExists(atPath: targetFile) else { return false }

        if !current.isEmpty && current != "?" && fm.fileExists(atPath: authFile) {
            let currentAccountFile = "\(accountsDir)/\(current).json"
            let tmpFile = currentAccountFile + ".tmp"
            do {
                if fm.fileExists(atPath: tmpFile) { try fm.removeItem(atPath: tmpFile) }
                try fm.copyItem(atPath: authFile, toPath: tmpFile)
                if fm.fileExists(atPath: currentAccountFile) { try fm.removeItem(atPath: currentAccountFile) }
                try fm.moveItem(atPath: tmpFile, toPath: currentAccountFile)
            } catch { try? fm.removeItem(atPath: tmpFile) }
        }

        do {
            if fm.fileExists(atPath: authFile) { try fm.removeItem(atPath: authFile) }
            try fm.copyItem(atPath: targetFile, toPath: authFile)
            try alias.write(toFile: currentFile, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }

    func syncAuthToAccounts() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: authFile) else { return }
        if !fm.isReadableFile(atPath: accountsDir) {
            try? fm.createDirectory(atPath: accountsDir, withIntermediateDirectories: true)
        }
        guard let authAccount = parseAccountFile(authFile, alias: "_tmp"), authAccount.email != "?" else { return }
        let accounts = listAccounts()
        if let existing = accounts.first(where: { $0.email == authAccount.email }) {
            let accountFile = "\(accountsDir)/\(existing.alias).json"
            try? fm.removeItem(atPath: accountFile)
            try? fm.copyItem(atPath: authFile, toPath: accountFile)
            try? existing.alias.write(toFile: currentFile, atomically: true, encoding: .utf8)
            return
        }
        var alias = authAccount.email.components(separatedBy: "@").first ?? "account"
        let existingAliases = Set(accounts.map { $0.alias })
        if existingAliases.contains(alias) {
            var i = 1
            while existingAliases.contains("\(alias)\(i)") { i += 1 }
            alias = "\(alias)\(i)"
        }
        try? fm.copyItem(atPath: authFile, toPath: "\(accountsDir)/\(alias).json")
        try? alias.write(toFile: currentFile, atomically: true, encoding: .utf8)
    }

    func deleteAccount(alias: String) -> Bool {
        let accountFile = "\(accountsDir)/\(alias).json"
        return (try? FileManager.default.removeItem(atPath: accountFile)) != nil
    }

    func parseAccountFile(_ path: String, alias: String) -> CodexAccount? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let authMode = json["auth_mode"] as? String ?? "chatgpt"
        let tokens = json["tokens"] as? [String: Any] ?? [:]
        let accountId = tokens["account_id"] as? String ?? "?"
        let accessToken = tokens["access_token"] as? String ?? ""
        var email = "?"; var plan = "?"
        var subStart: String?; var subUntil: String?; var daysRemaining: Int?; var tokenExpiry: Date?
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
            accountId: accountId, accessToken: accessToken,
            subscriptionStart: subStart, subscriptionUntil: subUntil,
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

// MARK: - Rate Limit Client

class RateLimitClient {
    private let apiURL = "https://chatgpt.com/backend-api/wham/usage"
    var usageByAlias: [String: FetchState] = [:]
    var lastFetchTime: Date?
    var onUpdate: (() -> Void)?

    func fetchAll(_ accounts: [CodexAccount]) {
        lastFetchTime = Date()
        for acct in accounts {
            if acct.accessToken.isEmpty || acct.accountId == "?" {
                usageByAlias[acct.alias] = .failed("No credentials")
                continue
            }
            // Only show loading if no previous data
            if usageByAlias[acct.alias] == nil { usageByAlias[acct.alias] = .loading }
            fetchForAccount(acct)
        }
        DispatchQueue.main.async { self.onUpdate?() }
    }

    func refreshIfNeeded(_ accounts: [CodexAccount], minInterval: TimeInterval) {
        if let last = lastFetchTime, Date().timeIntervalSince(last) < minInterval { return }
        fetchAll(accounts)
    }

    private func fetchForAccount(_ acct: CodexAccount) {
        guard let url = URL(string: apiURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(acct.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(acct.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex-switcher/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let alias = acct.alias
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if error != nil { self.setState(alias, .failed("Network error")); return }
            guard let http = response as? HTTPURLResponse, let data = data else {
                self.setState(alias, .failed("No response")); return
            }
            if http.statusCode == 401 { self.setState(alias, .failed("Token expired")); return }
            if http.statusCode != 200 { self.setState(alias, .failed("HTTP \(http.statusCode)")); return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.setState(alias, .failed("Parse error")); return
            }
            self.setState(alias, .success(self.parseResponse(json)))
        }.resume()
    }

    private func setState(_ alias: String, _ state: FetchState) {
        DispatchQueue.main.async { self.usageByAlias[alias] = state; self.onUpdate?() }
    }

    private func parseResponse(_ json: [String: Any]) -> RateLimitInfo {
        var primary: RateLimitWindow? = nil; var secondary: RateLimitWindow? = nil
        if let rl = json["rate_limit"] as? [String: Any] {
            primary = parseWindow(rl["primary_window"])
            secondary = parseWindow(rl["secondary_window"])
        }
        var credits: CreditsSnapshot? = nil
        if let c = json["credits"] as? [String: Any] {
            credits = CreditsSnapshot(hasCredits: c["has_credits"] as? Bool ?? false,
                unlimited: c["unlimited"] as? Bool ?? false, balance: c["balance"] as? String)
        }
        return RateLimitInfo(primary: primary, secondary: secondary, credits: credits, planType: json["plan_type"] as? String)
    }

    private func parseWindow(_ obj: Any?) -> RateLimitWindow? {
        guard let w = obj as? [String: Any] else { return nil }
        return RateLimitWindow(usedPercent: w["used_percent"] as? Int ?? 0,
            resetsAt: (w["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }
}

// MARK: - Menu Bar App

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let authManager = CodexAuthManager.shared
    private var fileMonitor: DispatchSourceFileSystemObject?
    private let rateLimitClient = RateLimitClient()
    private var refreshTimer: Timer?
    private var config = AppConfig.load()
    private var previousAlertState: (p5h: Bool, pWk: Bool) = (false, false)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rateLimitClient.onUpdate = { [weak self] in self?.updateMenu() }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        authManager.syncAuthToAccounts()
        updateMenu()
        watchAuthFile()
        rateLimitClient.fetchAll(authManager.listAccounts())
        scheduleTimer()
    }

    private func scheduleTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(config.refreshIntervalMinutes * 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.rateLimitClient.fetchAll(self.authManager.listAccounts())
        }
    }

    // Refresh on menu open (smart: skip if recent)
    func menuWillOpen(_ menu: NSMenu) {
        let minInterval = TimeInterval(config.minRefreshIntervalSeconds)
        rateLimitClient.refreshIfNeeded(authManager.listAccounts(), minInterval: minInterval)
    }

    // MARK: - Drawing Helpers

    /// AI character icons for status bar
    private func makeAIIcon(state: Int) -> NSImage {
        // state: 0 = standing (normal), 1 = tired (5h alert), 2 = lying (week alert)
        let s: CGFloat = 18
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        NSColor.black.setStroke()
        NSColor.black.setFill()

        switch state {
        case 2: drawLyingAI(s: s)
        case 1: drawTiredAI(s: s)
        default: drawStandingAI(s: s)
        }

        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    private func drawStandingAI(s: CGFloat) {
        let cx = s * 0.5
        // Antenna
        let antennaPath = NSBezierPath()
        antennaPath.move(to: NSPoint(x: cx, y: s * 0.78))
        antennaPath.line(to: NSPoint(x: cx, y: s * 0.88))
        antennaPath.lineWidth = 1.2; antennaPath.lineCapStyle = .round; antennaPath.stroke()
        NSBezierPath(ovalIn: NSRect(x: cx - 1.5, y: s * 0.88, width: 3, height: 3)).fill()

        // Head
        let headR: CGFloat = s * 0.15
        let headY = s * 0.65
        NSBezierPath(ovalIn: NSRect(x: cx - headR, y: headY, width: headR * 2, height: headR * 2)).stroke()
        // Eyes
        let eyeR: CGFloat = 1.2
        NSBezierPath(ovalIn: NSRect(x: cx - headR * 0.5 - eyeR, y: headY + headR * 0.7, width: eyeR * 2, height: eyeR * 2)).fill()
        NSBezierPath(ovalIn: NSRect(x: cx + headR * 0.5 - eyeR, y: headY + headR * 0.7, width: eyeR * 2, height: eyeR * 2)).fill()

        // Body
        let bodyPath = NSBezierPath()
        bodyPath.move(to: NSPoint(x: cx, y: headY))
        bodyPath.line(to: NSPoint(x: cx, y: s * 0.28))
        bodyPath.lineWidth = 1.5; bodyPath.lineCapStyle = .round; bodyPath.stroke()

        // Arms (up, like waving)
        let armPath = NSBezierPath()
        armPath.move(to: NSPoint(x: cx, y: s * 0.52))
        armPath.line(to: NSPoint(x: cx - s * 0.2, y: s * 0.6))
        armPath.move(to: NSPoint(x: cx, y: s * 0.52))
        armPath.line(to: NSPoint(x: cx + s * 0.2, y: s * 0.6))
        armPath.lineWidth = 1.3; armPath.lineCapStyle = .round; armPath.stroke()

        // Legs
        let legPath = NSBezierPath()
        legPath.move(to: NSPoint(x: cx, y: s * 0.28))
        legPath.line(to: NSPoint(x: cx - s * 0.14, y: s * 0.08))
        legPath.move(to: NSPoint(x: cx, y: s * 0.28))
        legPath.line(to: NSPoint(x: cx + s * 0.14, y: s * 0.08))
        legPath.lineWidth = 1.3; legPath.lineCapStyle = .round; legPath.stroke()
    }

    private func drawTiredAI(s: CGFloat) {
        let cx = s * 0.5
        // Antenna (drooping)
        let antennaPath = NSBezierPath()
        antennaPath.move(to: NSPoint(x: cx, y: s * 0.75))
        antennaPath.line(to: NSPoint(x: cx - s * 0.05, y: s * 0.83))
        antennaPath.lineWidth = 1.2; antennaPath.lineCapStyle = .round; antennaPath.stroke()
        NSBezierPath(ovalIn: NSRect(x: cx - s * 0.05 - 1.5, y: s * 0.82, width: 3, height: 3)).fill()

        // Head (slightly drooping)
        let headR: CGFloat = s * 0.15
        let headY = s * 0.6
        NSBezierPath(ovalIn: NSRect(x: cx - headR - s * 0.02, y: headY, width: headR * 2, height: headR * 2)).stroke()
        // Tired eyes (lines instead of dots)
        let eyePath = NSBezierPath()
        eyePath.move(to: NSPoint(x: cx - headR * 0.7, y: headY + headR * 0.85))
        eyePath.line(to: NSPoint(x: cx - headR * 0.1, y: headY + headR * 0.75))
        eyePath.move(to: NSPoint(x: cx + headR * 0.1, y: headY + headR * 0.85))
        eyePath.line(to: NSPoint(x: cx + headR * 0.7, y: headY + headR * 0.75))
        eyePath.lineWidth = 1.0; eyePath.lineCapStyle = .round; eyePath.stroke()

        // Body (slouching, slight curve)
        let bodyPath = NSBezierPath()
        bodyPath.move(to: NSPoint(x: cx - s * 0.02, y: headY))
        bodyPath.curve(to: NSPoint(x: cx, y: s * 0.24),
                       controlPoint1: NSPoint(x: cx + s * 0.05, y: s * 0.5),
                       controlPoint2: NSPoint(x: cx - s * 0.05, y: s * 0.35))
        bodyPath.lineWidth = 1.5; bodyPath.lineCapStyle = .round; bodyPath.stroke()

        // Arms (hanging down)
        let armPath = NSBezierPath()
        armPath.move(to: NSPoint(x: cx, y: s * 0.48))
        armPath.line(to: NSPoint(x: cx - s * 0.18, y: s * 0.32))
        armPath.move(to: NSPoint(x: cx, y: s * 0.48))
        armPath.line(to: NSPoint(x: cx + s * 0.18, y: s * 0.32))
        armPath.lineWidth = 1.3; armPath.lineCapStyle = .round; armPath.stroke()

        // Legs (wobbly)
        let legPath = NSBezierPath()
        legPath.move(to: NSPoint(x: cx, y: s * 0.24))
        legPath.line(to: NSPoint(x: cx - s * 0.12, y: s * 0.06))
        legPath.move(to: NSPoint(x: cx, y: s * 0.24))
        legPath.line(to: NSPoint(x: cx + s * 0.12, y: s * 0.06))
        legPath.lineWidth = 1.3; legPath.lineCapStyle = .round; legPath.stroke()

        // Sweat drop
        NSBezierPath(ovalIn: NSRect(x: cx + headR + 1, y: headY + headR * 0.5, width: 2, height: 3)).fill()
    }

    private func drawLyingAI(s: CGFloat) {
        let cy = s * 0.38
        // Ground line
        let groundPath = NSBezierPath()
        groundPath.move(to: NSPoint(x: s * 0.05, y: s * 0.15))
        groundPath.line(to: NSPoint(x: s * 0.95, y: s * 0.15))
        groundPath.lineWidth = 0.8; groundPath.lineCapStyle = .round; groundPath.stroke()

        // Lying body (horizontal)
        // Head (right side)
        let headR: CGFloat = s * 0.13
        let headX = s * 0.75
        NSBezierPath(ovalIn: NSRect(x: headX, y: cy - headR + s * 0.02, width: headR * 2, height: headR * 2)).stroke()
        // X eyes (knocked out)
        let exPath = NSBezierPath()
        let eyeCx1 = headX + headR * 0.6; let eyeCx2 = headX + headR * 1.4
        let eyeCy = cy + s * 0.05
        let ex: CGFloat = 1.5
        exPath.move(to: NSPoint(x: eyeCx1 - ex, y: eyeCy - ex)); exPath.line(to: NSPoint(x: eyeCx1 + ex, y: eyeCy + ex))
        exPath.move(to: NSPoint(x: eyeCx1 + ex, y: eyeCy - ex)); exPath.line(to: NSPoint(x: eyeCx1 - ex, y: eyeCy + ex))
        exPath.move(to: NSPoint(x: eyeCx2 - ex, y: eyeCy - ex)); exPath.line(to: NSPoint(x: eyeCx2 + ex, y: eyeCy + ex))
        exPath.move(to: NSPoint(x: eyeCx2 + ex, y: eyeCy - ex)); exPath.line(to: NSPoint(x: eyeCx2 - ex, y: eyeCy + ex))
        exPath.lineWidth = 1.0; exPath.lineCapStyle = .round; exPath.stroke()

        // Body (horizontal line)
        let bodyPath = NSBezierPath()
        bodyPath.move(to: NSPoint(x: headX, y: cy))
        bodyPath.line(to: NSPoint(x: s * 0.28, y: cy))
        bodyPath.lineWidth = 1.5; bodyPath.lineCapStyle = .round; bodyPath.stroke()

        // Legs (slightly bent, to the left)
        let legPath = NSBezierPath()
        legPath.move(to: NSPoint(x: s * 0.28, y: cy))
        legPath.line(to: NSPoint(x: s * 0.15, y: cy + s * 0.1))
        legPath.move(to: NSPoint(x: s * 0.28, y: cy))
        legPath.line(to: NSPoint(x: s * 0.12, y: cy - s * 0.08))
        legPath.lineWidth = 1.3; legPath.lineCapStyle = .round; legPath.stroke()

        // Arms (flopped)
        let armPath = NSBezierPath()
        armPath.move(to: NSPoint(x: s * 0.55, y: cy))
        armPath.line(to: NSPoint(x: s * 0.5, y: cy + s * 0.15))
        armPath.move(to: NSPoint(x: s * 0.45, y: cy))
        armPath.line(to: NSPoint(x: s * 0.42, y: cy - s * 0.12))
        armPath.lineWidth = 1.3; armPath.lineCapStyle = .round; armPath.stroke()

        // Zzz
        let zFont = NSFont.systemFont(ofSize: 6, weight: .bold)
        ("z" as NSString).draw(at: NSPoint(x: s * 0.82, y: s * 0.6), withAttributes: [
            .font: zFont, .foregroundColor: NSColor.black
        ])
        ("z" as NSString).draw(at: NSPoint(x: s * 0.72, y: s * 0.7), withAttributes: [
            .font: NSFont.systemFont(ofSize: 5, weight: .bold), .foregroundColor: NSColor.black
        ])
    }

    private func formatResetTime(_ date: Date?) -> String {
        guard let d = date else { return "" }
        let mins = Int(d.timeIntervalSinceNow / 60)
        if mins <= 0 { return "now" }
        if mins < 60 { return "\(mins)m" }
        let hours = mins / 60; let remMins = mins % 60
        if hours < 24 { return remMins > 0 ? "\(hours)h\(remMins)m" : "\(hours)h" }
        return "\(hours / 24)d\(hours % 24)h"
    }

    private func makeProgressBar(remaining: Int, width: CGFloat = 100, height: CGFloat = 8) -> NSImage {
        let pct = CGFloat(min(max(remaining, 0), 100)) / 100.0
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()

        let radius: CGFloat = 4
        let trackColor = NSColor.separatorColor.withAlphaComponent(0.3)
        let bgRect = NSRect(x: 0, y: 0, width: width, height: height)
        trackColor.setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius).fill()

        let fillWidth = width * pct
        if fillWidth > 0 {
            let window = RateLimitWindow(usedPercent: 100 - remaining, resetsAt: nil)
            let fillRect = NSRect(x: 0, y: 0, width: fillWidth, height: height)
            window.barColor.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
        }

        img.unlockFocus()
        return img
    }

    private func barAttachment(remaining: Int) -> NSAttributedString {
        let img = makeProgressBar(remaining: remaining)
        let att = NSTextAttachment()
        att.image = img
        att.bounds = NSRect(x: 0, y: 2, width: img.size.width, height: img.size.height)
        return NSAttributedString(attachment: att)
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - Build Menu

    private func updateMenu() {
        let current = authManager.currentAlias()
        let accounts = authManager.listAccounts()
        let active = accounts.first(where: { $0.alias == current })
        let others = accounts.filter { $0.alias != current }

        // Status bar - icon only, with red dot alerts
        if let button = statusItem.button {
            var alert5h = false, alertWk = false
            if let acct = active, case .success(let rl) = rateLimitClient.usageByAlias[acct.alias] {
                let p5h = rl.primary?.remaining ?? 100
                let pWk = rl.secondary?.remaining ?? 100
                alert5h = p5h < config.alert5hThreshold
                alertWk = pWk < config.alertWeekThreshold

                // Send notification on new alerts (not on every refresh)
                if alert5h && !previousAlertState.p5h {
                    sendNotification(title: "\(acct.alias) - 5h Quota Low",
                        body: "5h remaining: \(p5h)%")
                }
                if alertWk && !previousAlertState.pWk {
                    sendNotification(title: "\(acct.alias) - Weekly Quota Low",
                        body: "Weekly remaining: \(pWk)%")
                }
                previousAlertState = (alert5h, alertWk)

                button.toolTip = "Codex: \(acct.alias) | 5h: \(p5h)% | Week: \(pWk)%"
            } else {
                button.toolTip = "Codex: \(active?.alias ?? current)"
            }
            let iconState = alertWk ? 2 : (alert5h ? 1 : 0)
            button.image = makeAIIcon(state: iconState)
            button.title = ""
            button.imagePosition = .imageOnly
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.minimumWidth = 320

        // ─── Active Account ───
        if let acct = active {
            buildCard(menu, acct, isActive: true)
            menu.addItem(NSMenuItem.separator())
        }

        // ─── Other Accounts ───
        if !others.isEmpty {
            for (i, account) in others.enumerated() {
                buildCard(menu, account, isActive: false)
                if i < others.count - 1 { menu.addItem(NSMenuItem.separator()) }
            }
            menu.addItem(NSMenuItem.separator())
        }

        // ─── Actions ───
        addMenuItem(menu, "Refresh All", #selector(refreshUsage), "r")

        if !others.isEmpty {
            let removeItem = NSMenuItem(title: "Remove Account", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for acct in others {
                let item = NSMenuItem(title: acct.alias, action: #selector(deleteAccount(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = acct.alias
                sub.addItem(item)
            }
            removeItem.submenu = sub
            menu.addItem(removeItem)
        }

        menu.addItem(NSMenuItem.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.target = self
        if #available(macOS 13.0, *) {
            launchItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        } else { launchItem.isEnabled = false }
        menu.addItem(launchItem)

        // Settings submenu
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()

        // Auto refresh
        let refreshHeader = NSMenuItem(title: "Auto Refresh", action: nil, keyEquivalent: "")
        refreshHeader.isEnabled = false
        settingsMenu.addItem(refreshHeader)
        for (label, mins) in [("5 min", 5), ("15 min", 15), ("30 min", 30), ("1 hour", 60), ("2 hours", 120), ("Off", 0)] {
            let opt = NSMenuItem(title: "  \(label)", action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
            opt.target = self; opt.tag = mins
            opt.state = config.refreshIntervalMinutes == mins ? .on : .off
            settingsMenu.addItem(opt)
        }

        settingsMenu.addItem(NSMenuItem.separator())

        // 5h alert threshold
        let alert5hHeader = NSMenuItem(title: "5h Alert Below", action: nil, keyEquivalent: "")
        alert5hHeader.isEnabled = false
        settingsMenu.addItem(alert5hHeader)
        for pct in [10, 20, 30, 50] {
            let opt = NSMenuItem(title: "  \(pct)%", action: #selector(setAlert5hThreshold(_:)), keyEquivalent: "")
            opt.target = self; opt.tag = pct
            opt.state = config.alert5hThreshold == pct ? .on : .off
            settingsMenu.addItem(opt)
        }

        settingsMenu.addItem(NSMenuItem.separator())

        // Week alert threshold
        let alertWkHeader = NSMenuItem(title: "Week Alert Below", action: nil, keyEquivalent: "")
        alertWkHeader.isEnabled = false
        settingsMenu.addItem(alertWkHeader)
        for pct in [5, 10, 20, 30] {
            let opt = NSMenuItem(title: "  \(pct)%", action: #selector(setAlertWeekThreshold(_:)), keyEquivalent: "")
            opt.target = self; opt.tag = pct
            opt.state = config.alertWeekThreshold == pct ? .on : .off
            settingsMenu.addItem(opt)
        }

        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        addMenuItem(menu, "Quit", #selector(quit), "q")
        statusItem.menu = menu
    }

    private func addMenuItem(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private func buildCard(_ menu: NSMenu, _ acct: CodexAccount, isActive: Bool) {
        let item = NSMenuItem()
        let s = NSMutableAttributedString()
        let indent = isActive ? "  " : "  "

        // Row 1: alias + plan
        if isActive {
            s.append(NSAttributedString(string: "\u{25CF} ", attributes: [
                .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.systemGreen
            ]))
        }
        s.append(NSAttributedString(string: acct.alias, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: isActive ? .semibold : .medium),
            .foregroundColor: NSColor.labelColor
        ]))

        // Plan badge
        let badgeText = " \(acct.planLabel) "
        s.append(NSAttributedString(string: "  ", attributes: [.font: NSFont.systemFont(ofSize: 9)]))

        let badge = NSMutableAttributedString(string: badgeText, attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: acct.planColor,
            .backgroundColor: acct.planColor.withAlphaComponent(0.12),
            .baselineOffset: 2
        ])
        s.append(badge)

        // Row 2: email
        s.append(NSAttributedString(string: "\n\(indent) \(acct.email)", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))

        // Row 3-4: usage bars
        let state = rateLimitClient.usageByAlias[acct.alias] ?? .idle
        switch state {
        case .success(let rl):
            let labelFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            let labelColor = NSColor.tertiaryLabelColor
            let pctFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

            if let p = rl.primary {
                s.append(NSAttributedString(string: "\n\(indent) ", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
                s.append(NSAttributedString(string: "5h   ", attributes: [.font: labelFont, .foregroundColor: labelColor]))
                s.append(barAttachment(remaining: p.remaining))
                s.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
                let pctStr = String(format: "%3d%%", p.remaining)
                s.append(NSAttributedString(string: pctStr, attributes: [.font: pctFont, .foregroundColor: p.textColor]))
                if let r = p.resetsAt, p.remaining < 100 {
                    s.append(NSAttributedString(string: "  \(formatResetTime(r))", attributes: [
                        .font: NSFont.systemFont(ofSize: 9), .foregroundColor: labelColor]))
                }
            }
            if let sec = rl.secondary {
                s.append(NSAttributedString(string: "\n\(indent) ", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
                s.append(NSAttributedString(string: "Week ", attributes: [.font: labelFont, .foregroundColor: labelColor]))
                s.append(barAttachment(remaining: sec.remaining))
                s.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
                let pctStr = String(format: "%3d%%", sec.remaining)
                s.append(NSAttributedString(string: pctStr, attributes: [.font: pctFont, .foregroundColor: sec.textColor]))
                if let r = sec.resetsAt, sec.remaining < 100 {
                    s.append(NSAttributedString(string: "  \(formatResetTime(r))", attributes: [
                        .font: NSFont.systemFont(ofSize: 9), .foregroundColor: labelColor]))
                }
            }

        case .loading:
            s.append(NSAttributedString(string: "\n\(indent) Loading...", attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor
            ]))

        case .failed(let reason):
            s.append(NSAttributedString(string: "\n\(indent) \(reason)", attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1.0)
            ]))

        case .idle: break
        }

        item.attributedTitle = s
        if isActive {
            item.isEnabled = false
        } else {
            item.target = self; item.action = #selector(switchAccount(_:))
            item.representedObject = acct.alias
        }
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let alias = sender.representedObject as? String else { return }
        if authManager.switchTo(alias: alias) {
            updateMenu()
            // Refresh in background after a delay, don't block UI
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self = self else { return }
                self.rateLimitClient.fetchAll(self.authManager.listAccounts())
            }
            sendNotification(title: "Codex Account Switched", body: "Now using: \(alias)")
        } else {
            let a = NSAlert(); a.messageText = "Switch Failed"
            a.informativeText = "Could not switch to '\(alias)'"; a.alertStyle = .warning; a.runModal()
        }
    }

    @objc private func deleteAccount(_ sender: NSMenuItem) {
        guard let alias = sender.representedObject as? String else { return }
        if alias == authManager.currentAlias() {
            let a = NSAlert(); a.messageText = "Cannot Remove Active Account"
            a.informativeText = "Switch to another account first."; a.alertStyle = .warning; a.runModal()
            return
        }
        let c = NSAlert(); c.messageText = "Remove '\(alias)'?"
        c.informativeText = "You can re-add it later with Login."
        c.alertStyle = .warning; c.addButton(withTitle: "Remove"); c.addButton(withTitle: "Cancel")
        if c.runModal() == .alertFirstButtonReturn {
            if authManager.deleteAccount(alias: alias) {
                rateLimitClient.usageByAlias.removeValue(forKey: alias); updateMenu()
            }
        }
    }

    @objc private func refreshUsage() {
        rateLimitClient.fetchAll(authManager.listAccounts())
    }

    @objc private func setRefreshInterval(_ sender: NSMenuItem) {
        config.refreshIntervalMinutes = sender.tag
        config.save(); scheduleTimer(); updateMenu()
    }

    @objc private func setAlert5hThreshold(_ sender: NSMenuItem) {
        config.alert5hThreshold = sender.tag
        config.save(); previousAlertState = (false, false); updateMenu()
    }

    @objc private func setAlertWeekThreshold(_ sender: NSMenuItem) {
        config.alertWeekThreshold = sender.tag
        config.save(); previousAlertState = (false, false); updateMenu()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
                updateMenu()
            } catch {}
        }
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private var lastFileEventTime: Date = .distantPast
    private var authFileMonitor: DispatchSourceFileSystemObject?

    private func onAuthChanged() {
        let now = Date()
        guard now.timeIntervalSince(lastFileEventTime) > 2 else { return }
        lastFileEventTime = now
        authManager.syncAuthToAccounts()
        updateMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }
            self.rateLimitClient.fetchAll(self.authManager.listAccounts())
        }
    }

    private func watchAuthFile() {
        let codexDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")

        // Watch directory (catches new files, renames)
        let dirFd = open(codexDir.path, O_EVTONLY)
        if dirFd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFd, eventMask: [.write, .rename], queue: .main)
            source.setEventHandler { [weak self] in
                self?.onAuthChanged()
                // Re-watch auth.json in case it was recreated
                self?.watchAuthJsonFile()
            }
            source.setCancelHandler { close(dirFd) }
            source.resume()
            fileMonitor = source
        }

        watchAuthJsonFile()
    }

    private func watchAuthJsonFile() {
        // Cancel previous watcher
        authFileMonitor?.cancel()
        authFileMonitor = nil

        let authPath = authManager.authFile
        let authFd = open(authPath, O_EVTONLY)
        guard authFd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: authFd, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            self?.onAuthChanged()
            // File may have been replaced, re-watch
            self?.watchAuthJsonFile()
        }
        source.setCancelHandler { close(authFd) }
        source.resume()
        authFileMonitor = source
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
