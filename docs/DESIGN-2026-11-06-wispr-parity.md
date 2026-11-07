# FreeFlow: Wispr Flow parity for personal and team use (design, 6 Nov 2026)

Goal: FreeFlow does what Wispr Flow does for dictation, for Jamie and his team, with nothing leaving the Mac unless the user turns a cloud option on. Wispr's Notetaker (meeting recording) is out of scope.

## What Wispr Flow has (verified on wisprflow.ai/features, docs.wisprflow.ai, 6 Nov 2026) and what FreeFlow does

| Wispr Flow feature | FreeFlow today | Plan |
|---|---|---|
| Push-to-talk, hands-free lock, Esc cancels, 20 min sessions | Yes (6 min cap, Shift-lock instead of double-tap) | Raise cap to 20 min |
| Auto cleanup levels None / Light / Medium (fillers, grammar, self-corrections "actually make that 6pm", lists) | Rules only: fillers, hallucinations, dictionary swaps | Add Medium: local Qwen (Ollama) rewrite; Light stays rule-based; None = raw |
| Styles: tone per app (formal in Mail, casual in Slack/WhatsApp) | No | Medium mode reads frontmost app bundle id and picks a style; user can override per app in styles.txt |
| Command Mode: hold shortcut, speak instruction, selected text is edited and pasted back; no selection = draft | No | Add: second hotkey (default right ⌃), selection via AX then ⌘C fallback, local Qwen, paste replaces selection |
| Personal dictionary with wrong => right swaps, auto-learn | Yes (manual), prompt to Whisper + swaps | Keep; add "Add last word to dictionary" menu action |
| Snippets: spoken cue expands to saved text (cue 60 chars, expansion 4,000) | No | snippets.txt `cue => expansion`, matched case-insensitively on the cleaned transcript, whole dictation or inline |
| "Press enter" spoken command | No | Trailing "press enter" / "new line" / "new paragraph" commands |
| 100+ languages, auto-detect | 4 in menu, Whisper handles 99 | Add common languages to the menu (ja, ko, ta, hi, es, fr, de, id, vi, th) |
| History with "Undo AI edit" (raw kept) | history.txt, cleaned only | history.jsonl with raw, clean, app, mode; "Undo last AI edit" pastes the raw text |
| Usage stats: words, top apps | Words today / total | Words per app (top 5 in menu) |
| Team: shared dictionary, shared snippets, usage dashboard, admin | No | Team folder (any synced folder): team-dictionary.txt, team-snippets.txt, team-styles.txt; personal wins on conflicts; optional usage/<user>.json for a team view |
| MCP server so Claude/ChatGPT can read your content (Wispr: meetings only, OAuth) | No | Local stdio MCP (`scripts/freeflow-mcp.py`, stdlib Python): search_history, recent_dictations, dictionary, snippets, usage, add_dictionary_word, add_snippet |
| Install for teammates | Build only on this Mac | `build.sh release` -> zip + `install.sh` (brew whisper-cpp, model with sha256 check, strip quarantine, optional Ollama + qwen3.5:9b) |

## Decisions and why

1. **AI model: Ollama local Qwen 3.5 9B** (already installed). Tier rule: routine text work goes to local Qwen. No account, no cost, offline. If Ollama is not running the app falls back to Light and says so once. A cloud option (Ark Doubao) is not built; it can be added behind the same `Rewriter` interface later.
2. **Medium is not the default.** Light (rules) pastes in about 0.3 s. Medium adds the model round trip; it becomes the default only if measured latency on this Mac is under 1.5 s for a 40 word dictation. Measured value recorded below.
3. **Team sharing is files in a folder, not a server.** Teammates already share iCloud Drive or the NAS; the app only needs a folder path. No accounts, no admin portal. Conflicts: personal entry wins (same as Wispr).
4. **Command Mode on a separate modifier key**, never a chord with the talk key, so the existing tap/hold logic is untouched. Default right ⌃; choices are the same list as the talk key, minus the talk key.
5. **Signing**: only an Apple Development identity exists on this Mac (no Developer ID), so teammates' Gatekeeper would refuse the app. `install.sh` strips the quarantine attribute after copying, which is the standard workaround for unsigned internal tools. Notarisation needs a paid Developer ID and is a later step.
6. **Double-tap hands-free stays off** (Claude desktop Quick Entry owns double-tap Option). Shift-while-holding locks hands-free.

## Latency measurement

See `docs/MEASUREMENTS.md`: 0.75 to 0.85 s warm, so Medium became the default.

## Review outcome

Jev agreed with decisions 1, 2, 4 and the usage-sharing default; Codex's code review found six defects, all fixed: see `docs/reviews/2026-11-06-code-review-codex.md`. One addition from the review that changes behaviour: a result is pasted only if the app in front is still the one you spoke into; otherwise it is copied and the pill tells you.

## Out of scope

Notetaker/meeting recording, mobile apps, Voice Profile, Perplexity search from Command Mode, cloud sync of settings (the team folder covers dictionary and snippets).
