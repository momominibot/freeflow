# Purrscribe MCP: how each app adds a local server (checked 2026-11-10)

> The tiles on Settings > MCP are generated from `Sources/MCPApps.swift`, one entry per app below. Claude Desktop with Claude Code, and the ChatGPT app with Codex, share one tile with a button for each (10 setups, 8 tiles), so no maker's logo shows twice. The unit checks in `main.swift` keep each copied text in the shape the app expects. Apps that could not be tried on a real install say so in the tile's note. Windsurf (Devin Desktop), Kimi and Qwen Code are researched here but have no tile: their config paths conflict between sources or the command was not confirmed. Zed, Cline, Warp and Trae are researched here too, but their tiles were taken out on 11 Nov 2026 at the owner's request, so their sections below are reference only.
>
> The tiles copy `/usr/bin/env python3 <path>` as the command, so the app finds python the same way a terminal does. The research below uses `python3` for the shortest form.
> The brand pictures come from Simple Icons (CC0) via `scripts/art/make_app_logos.sh`; apps with no Simple Icons picture (ChatGPT, Doubao, VS Code) show the icon of the copy installed on the Mac, or letters on a colour. Brand rules are in section 3.


Server entry used everywhere: command `python3`, one arg `/ABS/PATH/freeflow-mcp.py`, name `freeflow`, no env.

How verified: vendor docs fetched this session. Where a fetched summary mattered (ChatGPT desktop, Doubao Work, Devin/Windsurf, Claude Desktop admin key) I re-read the raw page text with curl. Where a command line tool was available I also ran `--help` (claude, codex, hermes, code). Nothing was installed or changed, and no model calls were made.

## 1. Summary table

| App | Local stdio today? | Easiest copy-able setup | Primary doc |
|---|---|---|---|
| Claude Code (CLI) | YES | one shell command | code.claude.com/docs/en/mcp |
| Claude Desktop | YES | edit JSON file | modelcontextprotocol.io (protocol docs) + claude.com admin doc |
| Cursor | YES | JSON file (or deeplink) | cursor.com/docs/context/mcp |
| OpenAI Codex (CLI, IDE ext, desktop app) | YES | one shell command / TOML | developers.openai.com/codex/mcp |
| ChatGPT desktop app | YES, but only the Codex-capable desktop app, see note | UI form, or shared ~/.codex/config.toml | learn.chatgpt.com/docs/extend/mcp |
| Gemini CLI | YES | one shell command | github.com/google-gemini/gemini-cli docs |
| Doubao "Doubao Work" (豆包工作) client | YES (STDIO) | UI form only | doubao.com/work help center |
| Doubao regular chat app (web/phone/consumer) | NO official doc found, treat as no | none | none |
| Trae (ByteDance IDE) | YES | UI paste JSON / .trae/mcp.json | docs.trae.cn, docs.trae.ai |
| VS Code (Copilot agent mode) | YES | one shell command | code.visualstudio.com/docs/agents/reference/mcp-configuration |
| Windsurf (now "Devin Desktop") | YES, config path is messy, see note | JSON file | docs.devin.ai |
| Zed | YES | JSON in settings.json | zed.dev/docs/ai/mcp |
| Cline | YES | JSON via UI button | docs.cline.bot |
| Warp | YES | UI paste JSON or ~/.warp/.mcp.json | docs.warp.dev |
| Hermes Agent (extra) | YES | one shell command (verified locally) or YAML | hermes-agent.nousresearch.com |
| Qwen Code (extra) | YES | one shell command | qwenlm.github.io/qwen-code-docs |
| Kimi Code CLI (extra) | YES | JSON file or `/mcp-config` in TUI | kimi.com/code/docs |
| DeepSeek-based tools (extra) | not checked | | no first-party client doc looked up |

## 2. Per-app detail

### Claude Code (CLI): YES
```
claude mcp add --scope user --transport stdio freeflow -- python3 /ABS/PATH/freeflow-mcp.py
```
- Default scope is `local` (this project only). `--scope user` writes top level of `~/.claude.json`, available everywhere. `--scope project` writes `.mcp.json`.
- Equivalent JSON (`~/.claude.json` top level, or `.mcp.json`): `{"mcpServers":{"freeflow":{"type":"stdio","command":"python3","args":["/ABS/PATH/freeflow-mcp.py"]}}}` (`type` optional, no type is read as stdio).
- Verify: `claude mcp list`, or `/mcp` inside Claude Code.
- Doc: https://code.claude.com/docs/en/mcp . Also confirmed by local `claude mcp add --help`.

### Claude Desktop: YES
- File (macOS): `~/Library/Application Support/Claude/claude_desktop_config.json` (Settings > Developer > Edit Config creates/opens it). Merge in, do not overwrite other servers:
```json
{"mcpServers":{"freeflow":{"command":"python3","args":["/ABS/PATH/freeflow-mcp.py"]}}}
```
- Fully quit and reopen Claude Desktop afterwards. Logs: `~/Library/Logs/Claude/mcp*.log`.
- Docs: path and JSON from https://modelcontextprotocol.io/docs/develop/connect-local-servers (this is the MCP project's site, not claude.com; I found no claude.com page that prints the file path). Anthropic's own page confirms local stdio support: https://claude.com/docs/third-party/claude-desktop/configuration (key `isLocalDevMcpEnabled`, default true: "Lets users run local (stdio) MCP servers added in Developer settings"). Admins can switch it off.
- Anthropic's preferred route is packaged `.mcpb` Desktop Extensions (one-click), see https://www.anthropic.com/engineering/desktop-extensions (found in search, not read in full). Manual JSON still works.

### Cursor: YES
- File: `~/.cursor/mcp.json` (global) or `<project>/.cursor/mcp.json`:
```json
{"mcpServers":{"freeflow":{"type":"stdio","command":"python3","args":["/ABS/PATH/freeflow-mcp.py"]}}}
```
- The doc's field table lists `type: "stdio"` as required even though its example omits it, so include it.
- Deeplink exists: `cursor://anysphere.cursor-deeplink/mcp/install?name=freeflow&config=<BASE64 of JSON config>` (https://cursor.com/docs/context/mcp/install-links). I could not confirm whether the base64 JSON is the bare server object (`{"command":...,"args":[...]}`) or wrapped; test before shipping.
- Doc: https://cursor.com/docs/context/mcp

### OpenAI Codex (CLI, IDE extension, desktop app): YES
```
codex mcp add freeflow -- python3 /ABS/PATH/freeflow-mcp.py
```
- Writes `~/.codex/config.toml`:
```toml
[mcp_servers.freeflow]
command = "python3"
args = ["/ABS/PATH/freeflow-mcp.py"]
```
- Project-scoped `.codex/config.toml` only for trusted projects.
- Doc states: "The ChatGPT desktop app, Codex CLI, and IDE extension share this configuration." One setup covers all three.
- Doc: https://developers.openai.com/codex/mcp (308-redirects to https://learn.chatgpt.com/docs/extend/mcp). Local `codex mcp add --help` confirms the `-- <COMMAND>...` form.

### ChatGPT desktop app: YES per OpenAI's own doc, with caveats
- Raw page text (re-read with curl, not just a summary): "Configure in the ChatGPT desktop app: Open Settings, then select MCP servers. Select Add server. Enter a name, choose STDIO or Streamable HTTP, and provide the server's command or URL. Save the server, then select Restart."
- So tile steps: Settings > MCP servers > Add server > name `freeflow`, STDIO, command `python3`, args `/ABS/PATH/freeflow-mcp.py` > Save > Restart. Or paste the Codex TOML above, because the config is shared.
- Caveats, stated plainly:
  - The doc says MCP servers are "configured on a Codex host". The page says ChatGPT web does not read local config and uses only remote tools via plugins. So this is true only for the desktop app, not web or mobile.
  - I could not confirm from the page that ordinary (non-agent) chat turns call local stdio tools, or the macOS-specific build status (page sidebar lists Linux and Windows desktop sections; macOS not spelled out in what I read). Label the tile "ChatGPT desktop app" and test once on a real install before shipping.
- Doc: https://learn.chatgpt.com/docs/extend/mcp (linked from developers.openai.com/codex/mcp).

### Gemini CLI: YES
```
gemini mcp add -s user freeflow python3 /ABS/PATH/freeflow-mcp.py
```
- Syntax from docs: `gemini mcp add [options] <name> <command> [args...]`. Scope default is `project` (`.gemini/settings.json`), so pass `-s user` for `~/.gemini/settings.json`.
- Equivalent JSON: `{"mcpServers":{"freeflow":{"command":"python3","args":["/ABS/PATH/freeflow-mcp.py"]}}}`
- Docs say not to use underscores in server names (`freeflow` is fine).
- Doc: https://github.com/google-gemini/gemini-cli/blob/main/docs/tools/mcp-server.md (read raw). `gemini` is not installed here, so the CLI was not run.

### Doubao: split answer
- **Doubao Work (豆包工作) desktop client: YES, STDIO supported, UI form only, no file, no CLI.** Official help page text (read from raw HTML): path is 插件·技能·伙伴 > 插件 > top right "+ 添加" > "新建自定义连接器", fields: 服务器名称, 传输类型 "支持 HTTP 或 STDIO ... STDIO 用于连接本地运行的程序", and for STDIO "需要填写程序的运行命令、参数和环境变量" (example: command `npx`, args `-y @notionhq/notion-mcp-server`, env vars).
  - Purrscribe values: name `freeflow`, transport STDIO, command `python3`, args `/ABS/PATH/freeflow-mcp.py`, env empty.
  - The page does not state which OS builds have this. It talks about 本地电脑 / 云电脑. Page calls the entry "插件" (plugin) while the button says "自定义连接器".
  - Doc: https://www.doubao.com/work/docs/zh-cn/articles/705018132598-plugins
- **Regular Doubao chat app (consumer app/web/phone): no official doc for adding custom or local MCP servers found. Treat as NOT supported. Do not show a tile.**
- ByteDance's IDE **Trae: YES.** Settings > MCP > Add > 手动添加 (Create Manually) > paste, then confirm:
```json
{"mcpServers":{"freeflow":{"command":"python3","args":["/ABS/PATH/freeflow-mcp.py"]}}}
```
  - Docs warn the `command` value must not contain spaces ("python3" is fine; the path goes in args). Project-level: turn on the project MCP toggle in Settings > MCP, then create `<project>/.trae/mcp.json` with the same JSON.
  - Docs: https://docs.trae.cn/ide_add-mcp-servers (read in full). English page https://docs.trae.ai/ide/add-mcp-servers returned truncated text to my fetcher; a search summary of it matched the Chinese page. Trae also has an install-link page, https://docs.trae.ai/ide/mcp-server-install-links (not read).

### VS Code (GitHub Copilot agent mode): YES
```
code --add-mcp '{"name":"freeflow","type":"stdio","command":"python3","args":["/ABS/PATH/freeflow-mcp.py"]}'
```
- Adds to the user-profile `mcp.json`. Local `code --help` (VS Code 1.145.0) lists `--add-mcp <json>`.
- File alternative: `.vscode/mcp.json` or user profile (command palette: "MCP: Open User Configuration"). NOTE the VS Code format uses top-level `servers`, not `mcpServers`:
```json
{"servers":{"freeflow":{"type":"stdio","command":"python3","args":["/ABS/PATH/freeflow-mcp.py"]}}}
```
- Portable Copilot format (`.mcp.json` at workspace root, or `~/.copilot/mcp-config.json`) uses `mcpServers`. Do not mix them.
- A `vscode:mcp/install?...` deeplink is NOT documented in the current docs I read: unverified.
- Doc: https://code.visualstudio.com/docs/agents/reference/mcp-configuration

### Windsurf (renamed Devin Desktop): YES, but treat the naming and path as unstable
- Official FAQ: "Devin Desktop is the new name for Windsurf" (https://docs.devin.ai/desktop/devin-desktop-faq). windsurf.com now serves "Devin Desktop"; docs.windsurf.com 307-redirects to docs.devin.ai.
- Current default agent "Devin Local" reads (https://docs.devin.ai/desktop/cascade/mcp): user `~/.config/devin/mcp_config.json`, project `.devin/mcp_config.json`, local override `.devin/mcp_config.local.json`; supports stdio. Snippet:
```json
{"mcpServers":{"freeflow":{"command":"python3","args":["/ABS/PATH/freeflow-mcp.py"]}}}
```
- Devin CLI form (https://docs.devin.ai/cli/extensibility/mcp/configuration): `devin mcp add freeflow -- python3 /ABS/PATH/freeflow-mcp.py` (default scope is local, gitignored). Combining it with `-s user` for stdio is not shown in the doc: unverified.
- Legacy Cascade/editor discovery file: `~/.codeium/windsurf/mcp_config.json` for the stable build (https://docs.devin.ai/windsurf/plugins/cascade/mcp). The rename FAQ also lists `~/.codeium/mcp_config.json`. These three paths conflict. I could not reconcile which a given build uses. If a tile says "Windsurf", show the `~/.config/devin/mcp_config.json` path and say "Devin Desktop (formerly Windsurf)", or skip it until tested on a real install.

### Zed: YES
- Settings file macOS: `~/.config/zed/settings.json` (verified in Zed docs, configuring-zed.md). Merge key `context_servers` (NOT `mcpServers`):
```json
{"context_servers":{"freeflow":{"command":"python3","args":["/ABS/PATH/freeflow-mcp.py"],"env":{}}}}
```
- UI route: Settings > AI > MCP Servers > Add Server > Add Local Server. The settings file is JSONC, so merge by hand, do not overwrite.
- The docs example has no `"source"` key; UI-created entries may add one: unverified either way.
- Doc: https://zed.dev/docs/ai/mcp

### Cline: YES
- VS Code extension: Cline panel > MCP Servers (stacked server icon) > Configure tab > "Configure MCP Servers" opens `cline_mcp_settings.json`:
```json
{"mcpServers":{"freeflow":{"command":"python3","args":["/ABS/PATH/freeflow-mcp.py"],"disabled":false,"autoApprove":[]}}}
```
- Cline CLI file: `~/.cline/data/settings/cline_mcp_settings.json` (override with `CLINE_MCP_SETTINGS_PATH`).
- The docs give no macOS file path for the VS Code extension: unverified, so tell users to use the button.
- Doc: https://docs.cline.bot/mcp/configuring-mcp-servers

### Warp: YES
- UI: Settings > Agents > MCP servers (or Warp Drive > Personal > MCP Servers) > "+ Add" > choose the "CLI Server (Command)" type > paste JSON > click Start. Single-server paste form is NOT wrapped in `mcpServers`:
```json
{"freeflow":{"command":"python3","args":["/ABS/PATH/freeflow-mcp.py"]}}
```
- File route: global `~/.warp/.mcp.json` (project `.warp/.mcp.json`), which uses the wrapped form `{"mcpServers":{"freeflow":{...}}}`.
- Warp Agent CLI (separate product) reads `~/.warp_cli/.mcp.json` on macOS (https://docs.warp.dev/agents/cli/configuration/), same `mcpServers` format.
- No documented shell command to add a server.
- Doc: https://docs.warp.dev/agents/capabilities/mcp/

### Extras
- **Hermes Agent (Nous): YES.** `hermes mcp add freeflow --command python3 --args /ABS/PATH/freeflow-mcp.py` (flags confirmed by running `hermes mcp add --help` on this Mac; `--args` must be last). The public doc only shows `--preset`. Or `~/.hermes/config.yaml`:
```yaml
mcp_servers:
  freeflow:
    command: "python3"
    args: ["/ABS/PATH/freeflow-mcp.py"]
```
  Doc: https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp .
- **Qwen Code: YES.** `qwen mcp add -s user freeflow python3 /ABS/PATH/freeflow-mcp.py` (stdio is the default transport) or `~/.qwen/settings.json` with `{"mcpServers":{"freeflow":{"command":"python3","args":["/ABS/PATH/freeflow-mcp.py"]}}}`. Pass `-s user` explicitly: two sources disagreed on the default scope. Doc: https://qwenlm.github.io/qwen-code-docs/en/users/features/mcp/ .
- **Kimi Code CLI: YES via file.** `~/.kimi-code/mcp.json` (or `$KIMI_CODE_HOME/mcp.json`; project `.kimi-code/mcp.json`) with `{"mcpServers":{"freeflow":{"command":"python3","args":["/ABS/PATH/freeflow-mcp.py"]}}}`, or run `/mcp-config` in the TUI. Doc: https://www.kimi.com/code/docs/en/kimi-code-cli/customization/mcp.html . A `kimi mcp add ...` one-liner appears in blogs but is NOT on the official page, and the installed `kimi` here did not recognise an `mcp` subcommand: unverified, do not use.
- **DeepSeek-based tools:** DeepSeek itself ships no desktop/CLI client I looked up; third-party tools using DeepSeek models follow their own MCP docs. Not checked.

## 3. Logo-usage rules (brand/press pages)

None of these vendors publishes a clear "you may show our logo to indicate compatibility" rule except VS Code (text form only). A tile with the logo is a judgement call; the name in plain text is safer everywhere.

| Brand | Stated rule | Link |
|---|---|---|
| Anthropic (Claude, Claude Code, Claude Desktop) | NOT allowed without approval: "You may only use our trademarks as specifically permitted by us and only in materials we approve beforehand." No compatibility carve-out. Requests: marketing@anthropic.com | https://www.anthropic.com/legal/trademark-guidelines |
| Cursor | No third-party or compatibility rule on the page. Only: "Refer to us as Cursor. Not Cursor AI or Cursor Code." Unclear. | https://cursor.com/brand |
| OpenAI (Codex, ChatGPT) | Page blocks automated fetch (HTTP 403). From a search excerpt only, unverified: use logo as provided, no alterations, permission revocable, co-branding needs approval, requests to partnercomms@openai.com. | https://openai.com/brand/ |
| Google Gemini | No Gemini-specific third-party rule found. Google's general brand resource center says no permission needed if you follow its published guidance. Unverified for the Gemini mark. | https://about.google/brand-resource-center/ |
| VS Code (Microsoft) | Allows the wording "[Name] for Visual Studio Code" to say it works with VS Code. Do not use the icon to promote your own offering, do not modify it, do not put "VS Code" in product or domain names. So: text yes, icon as a compat tile is not clearly allowed. | https://code.visualstudio.com/brand |
| Windsurf / Devin Desktop | No third-party rule. "For any use not explicitly covered, please contact us with a visual mockup." Page now sits under Cognition/Devin branding. | https://windsurf.com/brand |
| Zed | No compat rule. General: no use "that could cause customer confusion"; no recolouring or distortion. | https://zed.dev/brand |
| Cline | No third-party rule stated. Only "Use the horizontal lockup where possible." | https://cline.bot/brand |
| Warp | Brand page had no logo-usage text in what I could read. | https://www.warp.dev/brand |
| Kimi / Moonshot | Guide shows logo variants only, no third-party rule; contact team@moonshot.ai. | https://moonshotai.github.io/Branding-Guide |
| Doubao, Trae, ByteDance | No official brand-usage page found. | n/a |
| Hermes Agent (Nous), Qwen, DeepSeek | Not checked. | n/a |

## 4. Simple Icons (CC0 SVGs), develop branch, latest release v16.37.0 (2026-11-08)

Checked by fetching `data/simple-icons.json` and probing `icons/<slug>.svg`. The CC0 licence covers the SVG files; brand trademarks stay with their owners (see section 3).

| Brand | Slug | In set? |
|---|---|---|
| Claude (Desktop) | `claude` | yes |
| Claude Code | `claudecode` | yes, but not bundled: Claude Code shares the Claude tile, so the page shows one Claude picture |
| Anthropic | `anthropic` | yes |
| Cursor | `cursor` | yes |
| OpenAI / ChatGPT / Codex | `openai` | NO. Removed 2025-11-29 (commit "Remove OpenAI (#13944)", prepared for v16.0.0 "assuming no permissions are sought/obtained"). No `chatgpt` or `codex` slug exists. Only `openaigym` remains. |
| Gemini CLI | `googlegemini` | yes (no separate Gemini CLI icon) |
| GitHub Copilot | `githubcopilot` | yes (entry carries an MIT licence field, source Primer, not plain CC0) |
| VS Code | `visualstudiocode` | NO. Removed 2024-06-28 ("Remove Microsoft brands (#10019)"). |
| Windsurf | `windsurf` | yes (entry points to windsurf.com/brand; product now renamed Devin Desktop; no `devin` slug) |
| Zed | `zedindustries` | yes (`zed` does not exist). No tile since 11 Nov 2026, so not bundled |
| Cline | `cline` | yes. No tile, not bundled |
| Warp | `warp` | yes. No tile, not bundled |
| Trae | `trae` | yes. No tile, not bundled |
| Doubao | none | NO. `bytedance` exists but is the company mark, not Doubao. |
| Kimi | `kimi` (also `moonshotai`) | yes (entry links Moonshot's branding guide) |
| Qwen | `qwen` | yes |
| DeepSeek | `deepseek` | yes |
| Hermes Agent (Nous) | none | NO. A `hermes` slug exists but it is the German parcel firm Hermes (source myhermes.de). Do not use it for Hermes Agent. The tile uses the app icon from Nous Research's own repository instead (`assets/icon-master.svg`, MIT), bundled as `hermes.png` with its notice in `assets/brand/apps/NOTICE.txt`. |
| MCP | `modelcontextprotocol` | yes |

## 5. Things to double check before shipping tiles
1. ChatGPT desktop app: run the Settings > MCP servers flow once on a real install (macOS build, chat vs Codex mode).
2. Windsurf/Devin Desktop: three conflicting config paths; test or drop the tile.
3. Doubao: only the Doubao Work client has STDIO; label the tile "Doubao Work" and do not claim the regular Doubao app.
4. Cursor deeplink payload shape (bare server object vs wrapped).
5. Claude Desktop and any app with one shared settings file: instruct "merge into existing file", never overwrite.
6. Logo use: Anthropic needs prior approval; VS Code icon use is restricted; OpenAI and VS Code have no Simple Icons SVG, so those tiles cannot use that set. Hermes Agent: the Nous Research repository is MIT and its README and LICENSE state no brand rules (checked 11 Nov 2026; the Nous website was not checked), so its icon is bundled with the notice kept beside it. The MIT licence covers the file, not the name or the mark.
7. Tiles (11 Nov 2026, at the owner's request): Claude Desktop and Claude Code share one "Claude" tile, and the ChatGPT app and Codex share one "ChatGPT" tile, each with a button per setup. This removed the two placeholder pictures (the Claude Code pixel mascot and the black ">_" Codex tile) and leaves one Claude picture. Hermes Agent has no Simple Icons picture and no installed app to borrow an icon from, so its tile uses the app icon from Nous Research's own repository (`assets/icon-master.svg`, MIT, as of commit c2b69de), bundled as `hermes.png`. `build.sh` copies the licence notice (`assets/brand/apps/NOTICE.txt`) into the app beside it, and `--test` checks that it is there. To drop the picture, remove `icon: "hermes"` from the Hermes entry in `Sources/MCPApps.swift`; the tile then falls back to letters. Zed, Cline, Warp and Trae lost their tiles the same day, at the owner's request: their entries, pictures and unit checks are removed and the research above stays as reference. Cline and Trae read a plain mcpServers list, so the Any other app tile covers them; Zed and Warp use their own shapes and would need a tile again.
