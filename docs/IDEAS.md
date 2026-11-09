# What would make FreeFlow better

Brainstormed 9 Nov 2026 from three sources: the people-ask list in `REDDIT-WISHLIST.md`, what the smoke test kept finding, and what Jamie said hurts day to day (repeating instructions to AI agents, never knowing whether a setup took, wanting the Mac to notice routines).

Rules every idea has to pass: it runs on this Mac, it keeps plain files, it needs no account, and it comes with a check in `scripts/smoke.sh` so "sometimes it works" cannot happen quietly.

## Built already

| Idea | Where |
|---|---|
| Dark royal purple, with Match my Mac | window, Settings > General |
| The AI tidy-up never holds typed words for long (about 5 seconds, then the plain text) | `Rewriter.cleanupBudget` |
| Workday notes: private activity log, no screenshots, redaction, exclusions, forget | `Sources/Workday.swift`, Workday page |
| Routines found three ways (morning apps, back-and-forth loops, repeated sentences) | `WorkdayAnalysis` |
| Scheduled task that opens your morning apps: dry-run check, add, remove | launchd, cron form shown |
| Hand a brief to the Hermes fleet or copy it for any agent | `Hermes`, `fleet-bridge` |
| A repeated sentence becomes a phrase you can say | Workday > Ideas |
| MCP `workday_summary` (apps and minutes only) and `workday_detail` (cleaned screen text and typing notes, if switched on) | `scripts/freeflow-mcp.py` |
| Deeper notes, each opt-in: the text on the front window, how I type (counts and finished lines), small pictures kept 3 days; redacted, 7-day expiry, forget, closer look by Hermes | `Sources/Detail.swift`, Workday page |
| Double tap of the talk key to start hands-free (Wispr-style); a card with the words when a dictation did not reach a text box | `Sources/Input.swift`, `Sources/Unsent.swift` |
| Learn from my own typing: a fix made twice is kept; accuracy meter | `Sources/Typing.swift`, Learning page |
| One command that checks every function | `scripts/smoke.sh` |

## Next, in the order I would do them

**1. A health page inside the app (small, high value).** Help > Run checks: microphone, typing permission, speech engine, local AI warm or cold, screen audio, free disk, last dictation time. Green or a one-click fix per line. This is the in-app version of the smoke test and answers "is it working?" without a terminal.

**2. Voice kickoff (small, answers the repeating-yourself problem).** Say "kick off" plus a goal in a project folder: FreeFlow runs `kickoff init`, pastes the brief with the standing rules (work start to end, verify by reproducing, name the playbook files you used), and shows the setup receipt (`kickoff check`) in the bar: green or the missing item. One sentence replaces the paragraph you retype, and the receipt says whether it took.

**3. Never lose a dictation (partly built).** Built: a card with Copy / Paste again when the words did not reach a text box. Still to do: paste last result on a key; an "Unsent" list; "scratch that" deletes the last dictation; retry any history row with a different tone or engine; keep the recording when transcription fails.

**4. Workday v2 (medium).**
- Weekly review written to Jots on Friday: where the time went, routines found, ideas not yet acted on.
- Status read-back: after Send to Hermes, the idea shows "queued, building, done" from the card.
- More task kinds an agent builds under the same check-add-remove pattern: run a command at a time, a report to Jots every morning, a reminder.
- Browser sites (needs the Automation permission, so opt-in per browser) so "Shopify admin, 3 hours" can be told from "Chrome".
- Per-app allow list for the deeper notes (today: everything except password managers, terminals, private windows and your own list).
- Let the deeper notes feed the ideas list directly: repeated typed lines and repeated screen text found without an agent.
- Ask about my week: a local model answers from the notes ("when did I last touch the EMIS theme?").

**5. Writing (medium).** A Rewrite level above Medium for people who want the AI to rephrase and expand; tone by category (personal, work, email, other) with a very casual option; language per app; file and folder names from a project folder added to the vocabulary so code and paths are spelled right.

**6. Meetings (medium).** Action items with owners; ask across all meetings; choose the notes folder (Obsidian); watch a folder and write down whatever audio lands in it; real speaker names.

**7. Mac integration (medium).** Shortcuts actions (dictate, rewrite, add a phrase), a Services-menu entry, and "Open with FreeFlow" for audio files.

## Not doing

- An account, a server, a subscription or cloud sync (use a folder you choose).
- Recording the screen as video, logging individual keystrokes, or reading the clipboard's contents. (The deeper notes keep screen text, typing counts and finished lines, cleaned, and only if switched on.)
- Letting any automation publish, send, spend or change a live account on its own. A task FreeFlow creates only opens apps; anything bigger goes to an agent as a brief and waits for a yes.
