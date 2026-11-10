import Foundation
import AppKit

/// The AI apps FreeFlow's MCP page can set up. Every app has its own way to add a local MCP server, so each one says
/// exactly what to copy and where to paste it. The steps were taken from each app's own documentation (see docs/MCP-APPS.md);
/// where an app could not be tried on a real install, its note says so.
struct MCPApp: Identifiable {
    enum Kind {
        case command, config, fields
        var button: String {
            switch self {
            case .command: return "Copy command"
            case .config: return "Copy config"
            case .fields: return "Copy fields"
            }
        }
    }

    let id: String
    let name: String
    let kind: Kind
    /// A bundled brand picture in Brand/apps (Simple Icons, CC0). Nil for apps that have none.
    let glyph: String?
    /// The installed app's own icon is used when there is no bundled picture. The names are looked for in /Applications.
    let appNames: [String]
    /// Last resort: letters on a coloured tile.
    let letters: String
    let tint: UInt32
    /// What to do after copying, in plain words.
    let steps: String
    /// What is copied, given the full path of freeflow-mcp.py.
    let text: (String) -> String
}

enum MCPApps {
    /// FreeFlow's server, started the way every app starts a local one: a command and its arguments.
    static let command = "/usr/bin/env"
    static func arguments(_ script: String) -> [String] { ["python3", script] }

    static var scriptPath: String {
        (Bundle.main.resourcePath ?? "/Applications/FreeFlow.app/Contents/Resources") + "/freeflow-mcp.py"
    }

    /// A path as one shell word: plain double quotes when that is safe, single quotes when the path has anything a shell would read.
    static func shellArg(_ s: String) -> String {
        let risky = CharacterSet(charactersIn: "\"$`\\!'")
        if s.rangeOfCharacter(from: risky) == nil { return "\"" + s + "\"" }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func json(_ object: Any, pretty: Bool = true) -> String {
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func server(_ script: String, extra: [String: Any] = [:]) -> [String: Any] {
        var entry: [String: Any] = ["command": command, "args": arguments(script)]
        for (k, v) in extra { entry[k] = v }
        return entry
    }

    /// The common "mcpServers" list that Claude Desktop, Cursor, Cline, Trae and most other apps read.
    static func mcpServers(_ script: String, extra: [String: Any] = [:]) -> String {
        json(["mcpServers": ["freeflow": server(script, extra: extra)]])
    }

    static let all: [MCPApp] = [
        MCPApp(id: "claudecode", name: "Claude Code", kind: .command, glyph: "claudecode", appNames: [], letters: "CC", tint: 0xD97757,
               steps: "Paste it in a terminal and press Return. Claude Code can then search your dictations in every project. Check with claude mcp list.",
               text: { "claude mcp add --scope user freeflow -- \(command) python3 \(shellArg($0))" }),
        MCPApp(id: "claude", name: "Claude Desktop", kind: .config, glyph: "claude", appNames: ["Claude.app"], letters: "C", tint: 0xD97757,
               steps: "In Claude open Settings, then Developer, then Edit Config. Put the freeflow entry inside mcpServers and keep any servers already there. Save, then quit and reopen Claude.",
               text: { mcpServers($0) }),
        MCPApp(id: "chatgpt", name: "ChatGPT", kind: .fields, glyph: nil, appNames: ["ChatGPT.app"], letters: "G", tint: 0x10A37F,
               steps: "In the ChatGPT desktop app open Settings, then MCP servers, then Add server. Choose STDIO, fill in the three fields, save and restart. Not tried on a real install here, and the ChatGPT website and phone app cannot use a server on your Mac.",
               text: { "Name: freeflow\nType: STDIO\nCommand: python3\nArguments: \($0)" }),
        MCPApp(id: "codex", name: "Codex", kind: .command, glyph: nil, appNames: [], letters: ">_", tint: 0x1F1F1F,
               steps: "Paste it in a terminal and press Return. The Codex command line, its editor extension and the ChatGPT desktop app share one list of servers.",
               text: { "codex mcp add freeflow -- \(command) python3 \(shellArg($0))" }),
        MCPApp(id: "cursor", name: "Cursor", kind: .config, glyph: "cursor", appNames: ["Cursor.app"], letters: "Cu", tint: 0x000000,
               steps: "Open ~/.cursor/mcp.json and put the freeflow entry inside mcpServers, keeping any others. Cursor picks it up without a restart.",
               text: { mcpServers($0, extra: ["type": "stdio"]) }),
        MCPApp(id: "gemini", name: "Gemini CLI", kind: .command, glyph: "googlegemini", appNames: [], letters: "G", tint: 0x8E75B2,
               steps: "Paste it in a terminal and press Return. -s user adds it for every project, not only the current folder.",
               text: { "gemini mcp add -s user freeflow \(command) python3 \(shellArg($0))" }),
        MCPApp(id: "doubao", name: "Doubao Work", kind: .fields, glyph: nil, appNames: ["Doubao.app"], letters: "豆", tint: 0x3D6BFF,
               steps: "In Doubao Work open Plugins, then Plugins, then + Add, then New custom connector. Choose STDIO and fill in the fields. The regular Doubao chat app has no place to add your own MCP server.",
               text: { "Name: freeflow\nType: STDIO\nCommand: python3\nArguments: \($0)" }),
        MCPApp(id: "vscode", name: "VS Code", kind: .command, glyph: nil, appNames: ["Visual Studio Code.app"], letters: "VS", tint: 0x007ACC,
               steps: "Paste it in a terminal and press Return. It adds FreeFlow to your user profile, so GitHub Copilot's agent mode can use it in every window.",
               text: { script in
                   let entry = json(["name": "freeflow", "type": "stdio", "command": command, "args": arguments(script)], pretty: false)
                   return "code --add-mcp '" + entry.replacingOccurrences(of: "'", with: "'\\''") + "'"
               }),
        MCPApp(id: "zed", name: "Zed", kind: .config, glyph: "zedindustries", appNames: ["Zed.app"], letters: "Z", tint: 0x084CCF,
               steps: "In Zed open Settings (the settings.json file) and put the freeflow entry inside context_servers, keeping any others. It is context_servers here, not mcpServers.",
               text: { json(["context_servers": ["freeflow": server($0, extra: ["env": [String: String]()])]]) }),
        MCPApp(id: "cline", name: "Cline", kind: .config, glyph: "cline", appNames: [], letters: "Cl", tint: 0x18181B,
               steps: "In the Cline panel in VS Code open MCP Servers, then Configure, then Configure MCP Servers. Put the freeflow entry inside mcpServers and save.",
               text: { mcpServers($0, extra: ["disabled": false, "autoApprove": [String]()]) }),
        MCPApp(id: "warp", name: "Warp", kind: .config, glyph: "warp", appNames: ["Warp.app"], letters: "W", tint: 0x01A4FF,
               steps: "In Warp open Settings, then Agents, then MCP servers, then + Add. Paste this as it is and click Start.",
               text: { json(["freeflow": server($0)]) }),
        MCPApp(id: "trae", name: "Trae", kind: .config, glyph: "trae", appNames: ["Trae.app", "TRAE.app"], letters: "T", tint: 0x32F08C,
               steps: "In Trae open Settings, then MCP, then Add, then Add manually. Paste this and confirm.",
               text: { mcpServers($0) }),
        MCPApp(id: "hermes", name: "Hermes", kind: .command, glyph: nil, appNames: [], letters: "H", tint: 0x6B4FA3,
               steps: "Paste it in a terminal and press Return. Hermes agents then see FreeFlow's tools next time they start.",
               text: { "hermes mcp add freeflow --command \(command) --args python3 \(shellArg($0))" }),
        MCPApp(id: "other", name: "Any other app", kind: .config, glyph: "modelcontextprotocol", appNames: [], letters: "MCP", tint: 0x000000,
               steps: "Most apps that run local MCP servers read an mcpServers list in their settings. Add this entry to it.",
               text: { mcpServers($0) }),
    ]

    static func app(_ id: String) -> MCPApp? { all.first { $0.id == id } }

    /// The installed copy of an app, looked for in /Applications and ~/Applications.
    static func installedURL(_ names: [String]) -> URL? {
        let fm = FileManager.default
        for dir in ["/Applications", Paths.home.appendingPathComponent("Applications").path] {
            for name in names where fm.fileExists(atPath: dir + "/" + name) { return URL(fileURLWithPath: dir + "/" + name) }
        }
        return nil
    }
}
