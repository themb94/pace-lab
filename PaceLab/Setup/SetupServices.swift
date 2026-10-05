import AppKit
import Foundation

struct SetupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Trainingsordner

/// Legt den Trainingsordner aus der Vorlage im App-Bundle an (Template/).
enum TrainingFolderSetup {
    static let files = ["plan.json", "analysis.json", "completed.json", "README.md"]

    /// Vorlage in der Sprache der App (Template/<Sprache> im App-Bundle), sonst die englische.
    static var templateURL: URL? {
        guard let root = Bundle.main.url(forResource: "Template", withExtension: nil) else { return nil }
        let localized = root.appending(path: AppLanguage.code, directoryHint: .isDirectory)
        let folder = FileManager.default.fileExists(atPath: localized.path) ? localized : root.appending(path: "en", directoryHint: .isDirectory)
        return folder
    }

    static func isReady(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appending(path: TrainingFiles.plan).path)
            && fm.fileExists(atPath: folder.appending(path: TrainingFiles.analysis).path)
    }

    /// Legt fehlende Dateien an (vorhandene bleiben unangetastet) und startet den Verlauf (git).
    /// Der Beispielplan beginnt am nächsten Montag.
    static func create(at folder: URL, today: Date = .now) async throws {
        guard let template = templateURL else { throw SetupError(String(localized: "The template is missing from the app bundle.")) }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files {
            let target = folder.appending(path: name)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try fm.copyItem(at: template.appending(path: name), to: target)
            if name == TrainingFiles.plan {
                var document = try JSONDocument(contentsOf: target, style: .compact(width: 120))
                let monday = DateUtil.startOfWeek(today)
                let start = DateUtil.days(from: monday, to: today) == 0 ? monday
                    : DateUtil.calendar.date(byAdding: .day, value: 7, to: monday)!
                document.root["startMonday"] = .string(DateUtil.iso(start))
                try document.write(to: target)
            }
        }
        try await ProjectHistory(folder: folder).setUp()
    }
}

// MARK: - Python

/// Sucht ein Python ab 3.10 (das MCP-Paket braucht es; das Python von macOS ist älter).
enum PythonFinder {
    struct Found: Sendable {
        let url: URL
        let version: String
    }

    static func find() -> Found? {
        var candidates: [String] = []
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"] {
            for minor in stride(from: 20, through: 10, by: -1) { candidates.append("\(dir)/python3.\(minor)") }
            candidates.append("\(dir)/python3")
        }
        candidates.append("/usr/bin/python3")
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let output = ProcessRunner.run(URL(filePath: path), ["-c", "import sys; print('%d.%d' % sys.version_info[:2])"])
            let version = output.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = version.split(separator: ".").compactMap { Int($0) }
            if output.status == 0, parts.count == 2, parts[0] == 3, parts[1] >= 10 {
                return Found(url: URL(filePath: path), version: version)
            }
        }
        return nil
    }
}

// MARK: - Garmin

/// Der Garmin-Server (MCP) kommt aus dem App-Bundle und bekommt eine eigene Python-Umgebung in
/// Application Support. Die Anmeldung speichert nur ein Token in ~/.garminconnect — kein Passwort.
enum GarminSetup {
    static var directory: URL { AppSettings.supportDirectory.appending(path: "garmin-mcp", directoryHint: .isDirectory) }
    static var python: URL { directory.appending(path: ".venv/bin/python") }
    static var server: URL { directory.appending(path: "server.py") }
    static var tokenStore: String { "\(NSHomeDirectory())/.garminconnect" }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path) && FileManager.default.fileExists(atPath: server.path)
    }

    static var hasToken: Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: tokenStore)) ?? []
        return files.contains { $0.hasSuffix(".json") }
    }

    /// Kopiert den Server, legt die Python-Umgebung an und installiert garminconnect + mcp.
    static func install(progress: @Sendable (String) -> Void) throws {
        guard let bundled = Bundle.main.url(forResource: "garmin-mcp", withExtension: nil) else {
            throw SetupError(String(localized: "The Garmin server is missing from the app bundle."))
        }
        guard let python = PythonFinder.find() else {
            throw SetupError(String(localized: "Python 3.10 or newer is missing. Install it e.g. with “brew install python” or from python.org and then try again."))
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["server.py", "garmin_workouts.py", "login.py", "requirements.txt"] {
            let target = directory.appending(path: name)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: bundled.appending(path: name), to: target)
        }
        if !fm.isExecutableFile(atPath: self.python.path) {
            progress(String(localized: "Creating Python environment (Python \(python.version)) …"))
            try run(python.url, ["-m", "venv", directory.appending(path: ".venv").path])
        }
        progress(String(localized: "Installing packages (garminconnect, mcp) — may take a minute …"))
        try run(self.python, ["-m", "pip", "install", "--disable-pip-version-check", "-q", "-r",
                              directory.appending(path: "requirements.txt").path])
    }

    /// Trägt den Server in die .mcp.json des Trainingsordners ein; andere Einträge bleiben erhalten.
    static func writeConfig(folder: URL) throws {
        let url = folder.appending(path: ".mcp.json")
        var root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["garmin-workouts"] = [
            "command": python.path,
            "args": [server.path],
            "env": ["GARMIN_TOKENSTORE": tokenStore, "PACELAB_PLAN": folder.appending(path: TrainingFiles.plan).path],
        ]
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws {
        let result = ProcessRunner.run(executable, arguments)
        guard result.status == 0 else {
            let details = (result.error + result.output).split(separator: "\n").suffix(4).joined(separator: "\n")
            throw SetupError(String(localized: "\(executable.lastPathComponent) \(arguments.prefix(2).joined(separator: " ")) failed:\n\(details)"))
        }
    }
}

/// Garmin-Anmeldung in der App: E-Mail und Passwort gehen nur an den lokalen Garmin-Server
/// (Umgebungsvariablen des Prozesses), gespeichert wird allein das Token.
@MainActor
@Observable
final class GarminLogin {
    enum Phase: Equatable {
        case idle, working, needsCode, done(String), failed(String)
    }

    var email = ""
    var password = ""
    var code = ""
    private(set) var phase = Phase.idle
    private var client: MCPClient?

    func start(folder: URL) async {
        guard let config = GarminServerConfig.load(from: folder) else {
            phase = .failed(String(localized: "Set up the Garmin server first."))
            return
        }
        phase = .working
        do {
            let client = try await config.connect(in: folder, readOnly: true,
                                                  extraEnvironment: ["GARMIN_EMAIL": email, "GARMIN_PASSWORD": password])
            self.client = client
            password = ""
            handle(try await client.callTool("garmin_login", timeout: 90))
        } catch {
            finish(.failed(error.localizedDescription))
        }
    }

    func submitCode() async {
        guard let client else { return }
        phase = .working
        do {
            handle(try await client.callTool("garmin_submit_mfa", arguments: ["code": code], timeout: 90))
        } catch {
            finish(.failed(error.localizedDescription))
        }
    }

    func cancel() {
        finish(.idle)
    }

    private func handle(_ text: String) {
        if text.contains("MFA") && !text.hasPrefix("✅") {
            phase = .needsCode
        } else if text.hasPrefix("✅") {
            finish(.done(text.replacingOccurrences(of: "✅ ", with: "")))
        } else {
            finish(.failed(text.replacingOccurrences(of: "❌ ", with: "")))
        }
    }

    private func finish(_ phase: Phase) {
        client?.close()
        client = nil
        password = ""
        code = ""
        self.phase = phase
    }
}

// MARK: - Strava (über Claude Code)

/// Strava gibt es nur über Strava's MCP-Server in Claude Code; die Anmeldung läuft im Browser.
enum StravaSetup {
    static let url = "https://mcp.strava.com/mcp"

    enum Status: Equatable {
        case noClaude, missing, needsLogin, connected
        case unknown(String)
    }

    static func status(folder: URL) -> Status {
        guard let claude = CLIResolver.find("claude") else { return .noClaude }
        let result = ProcessRunner.run(claude, ["mcp", "get", "strava-mcp"], in: folder)
        let text = result.output + result.error
        if text.contains("No MCP server named") { return .missing }
        if text.contains("Connected") { return .connected }
        if text.localizedCaseInsensitiveContains("auth") { return .needsLogin }
        return .unknown(text.split(separator: "\n").first(where: { $0.contains("Status") }).map(String.init) ?? String(localized: "unknown"))
    }

    /// Trägt den Strava-Server für diesen Ordner in Claude Code ein (nur für dich, nicht im Ordner).
    static func add(folder: URL) throws {
        guard let claude = CLIResolver.find("claude") else { throw CoachError.notFound("claude") }
        let result = ProcessRunner.run(claude, ["mcp", "add", "--transport", "http", "strava-mcp", url], in: folder)
        guard result.status == 0 else {
            throw SetupError("Claude Code: \((result.error + result.output).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    static func openLogin(folder: URL) {
        let claude = CLIResolver.find("claude")?.path ?? "claude"
        Terminal.run("cd \(Terminal.quote(folder.path)) && \(Terminal.quote(claude)) mcp login strava-mcp", name: "strava-login")
    }
}

// MARK: - Coach-CLIs

enum CLISetup {
    struct Info: Sendable {
        let path: String?
        let version: String?
        let loggedIn: Bool?
    }

    static func claude() -> Info {
        guard let url = CLIResolver.find("claude") else { return Info(path: nil, version: nil, loggedIn: nil) }
        let status = ProcessRunner.run(url, ["auth", "status"]).output
        let loggedIn = (try? JSONSerialization.jsonObject(with: Data(status.utf8)) as? [String: Any])?["loggedIn"] as? Bool
        return Info(path: url.path, version: ModelDiscovery.cliVersion(url), loggedIn: loggedIn)
    }

    static func codex() -> Info {
        guard let url = CLIResolver.find("codex") else { return Info(path: nil, version: nil, loggedIn: nil) }
        let result = ProcessRunner.run(url, ["login", "status"])
        let text = result.output + result.error
        return Info(path: url.path, version: ModelDiscovery.cliVersion(url),
                    loggedIn: result.status == 0 && text.localizedCaseInsensitiveContains("logged in"))
    }

    static func lmStudio() -> Info {
        let url = CLIResolver.find("lms")
        return Info(path: url?.path, version: nil, loggedIn: nil)
    }
}

// MARK: - Terminal

/// Öffnet ein Terminal-Fenster mit einem Befehl (über eine .command-Datei — ohne Automations-Rechte).
enum Terminal {
    static func run(_ command: String, name: String) {
        let url = FileManager.default.temporaryDirectory.appending(path: "pacelab-\(name).command")
        let script = "#!/bin/zsh -l\nclear\n\(command)\necho\necho \(quote(String(localized: "Done — you can close this window.")))\n"
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
