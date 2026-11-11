# What would make Purrscribe better

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
| Hermes hand-over: `hermes kanban create` to Levi (or Eren), Test the connection button; web-content boxes are trusted by the "did not reach a text box" card | `Sources/Workday.swift`, `Sources/Unsent.swift` |
| Learn from my own typing: a clear spelling fix is kept the first time (after 20 s), anything less clear when made twice; accuracy meter | `Sources/Typing.swift`, Learning page |
| Polish: spelling, grammar, punctuation, clarity and style suggestions with one-click fixes, tone and reading time, seven rewrites, word swaps; also on selected text anywhere and (off by default) on what you dictate | `Sources/Polish.swift`, `Sources/PolishPage.swift`, Polish page |
| For AI builders: seven rewrites (coding prompt, plan, bug report, commit, conventional commit, pull request, code comment) with a guard that refuses a rewrite that lost a file name, flag or number; spoken code names ("camel case ...", "index dot ts") | `Sources/Polish.swift`, `Sources/Text.swift` (`CodeSpeech`), `docs/AI-BUILDERS.md` |
| Cute cats Look (Rhea and Rhythme's kitten paintings, cat face on the bar and menu bar, cat Dock and app icon) with a switch back to the pearly bubble | `Sources/Theme.swift`, `scripts/art/make_cat_art.py` |
| Two colourways (Dreamy: lavender and plum; Sunset: butter, cream and espresso), six cats living on a transparent strip on top of the Studio window (ball, wand with a ribbon, fish biscuits, poop to clean up) with a tiny toy box in the sidebar, Reduce Motion hides them, a cursive wordmark | `Sources/Theme.swift`, `Sources/CatRunner.swift`, `Sources/CatPerch.swift`, `scripts/art/` |
| MCP page with one brand-picture tile per maker (Claude Desktop and Claude Code, ChatGPT and Codex, Cursor, Gemini CLI, Doubao Work, VS Code, Hermes, other): click to copy what that app expects, with next steps | `Sources/MCPApps.swift`, `docs/MCP-APPS.md` |
| How Wispr Flow and Grammarly work on the phone, from public sources | `docs/REFERENCE-WISPR-GRAMMARLY.md` |
| One command that checks every function | `scripts/smoke.sh` |

## Next, in the order I would do them

**1. A health page inside the app (small, high value).** Help > Run checks: microphone, typing permission, speech engine, local AI warm or cold, screen audio, free disk, last dictation time. Green or a one-click fix per line. This is the in-app version of the smoke test and answers "is it working?" without a terminal.

**2. Voice kickoff (small, answers the repeating-yourself problem).** Say "kick off" plus a goal in a project folder: Purrscribe runs `kickoff init`, pastes the brief with the standing rules (work start to end, verify by reproducing, name the playbook files you used), and shows the setup receipt (`kickoff check`) in the bar: green or the missing item. One sentence replaces the paragraph you retype, and the receipt says whether it took.

**3. Never lose a dictation (partly built).** Built: a card with Copy / Paste again when the words did not reach a text box. Still to do: paste last result on a key; an "Unsent" list; "scratch that" deletes the last dictation; retry any history row with a different tone or engine; keep the recording when transcription fails.

**4. Workday v2 (medium).**
- Weekly review written to Jots on Friday: where the time went, routines found, ideas not yet acted on.
- Status read-back: after Send to Hermes, the idea shows "queued, building, done" from the card.
- More task kinds an agent builds under the same check-add-remove pattern: run a command at a time, a report to Jots every morning, a reminder.
- Browser sites (needs the Automation permission, so opt-in per browser) so "Shopify admin, 3 hours" can be told from "Chrome".
- Per-app allow list for the deeper notes (today: everything except password managers, terminals, private windows and your own list).
- Let the deeper notes feed the ideas list directly: repeated typed lines and repeated screen text found without an agent.
- Ask about my week: a local model answers from the notes ("when did I last touch the EMIS theme?").

**5. Writing (medium).** Polish is built (see above). Still to do: Polish suggestions live under the cursor as you type in any app (Grammarly's underlines; needs the Accessibility text API per app, so opt-in), a plagiarism-style "is this too close to a source" check (not planned), a Polish goal per document (audience, formality, intent) like Grammarly's goals, and a weekly writing report. Also: a Rewrite level above Medium for people who want the AI to rephrase and expand; tone by category (personal, work, email, other) with a very casual option; language per app; file and folder names from a project folder added to the vocabulary so code and paths are spelled right.

**5b. For AI builders, next steps.** Built: see `docs/AI-BUILDERS.md`. Not built: one key that speaks a prompt in one step (hold, talk, a structured prompt is typed; needs its own guard because dictation tidy-up expects the same words back), reading the project's `CLAUDE.md` or `AGENTS.md` to add its conventions to a prompt, file tagging from the editor, answering a coding agent by voice.

**6. Meetings (medium).** Action items with owners; ask across all meetings; choose the notes folder (Obsidian); watch a folder and write down whatever audio lands in it; real speaker names.

**7. Mac integration (medium).** Shortcuts actions (dictate, rewrite, add a phrase), a Services-menu entry, and "Open with Purrscribe" for audio files.

**8. An "AI model" card in Settings (small, answers "what is it using?").** Today the tidy-up uses Qwen 3.5 9B in Ollama, and Settings mentions Ollama only in passing (the Tidy-up row, and the note under Edit by voice when it is not running). Nothing shows which model it is, whether it is warm or how big it is. One card under Settings: which model is used, whether Ollama is running and warm, how big the model is on disk (7.6 GB), a **Start** or **Install** button when it is not there, a **Test it** button that cleans up one sentence and shows the time, and later a choice of a smaller model for Macs with less memory. Green or one click to fix, in the same style as the health page in idea 1.

**9. One-click model setup for friends (medium, the main thing standing between a friend and a working app).** *Partly done on 11 Nov 2026: the guided part exists.* A new **Help › The local AI** page shows what the Mac has (speech model, Ollama, the rewrite model), the next step with buttons (Get Ollama, Open Ollama, a copyable `ollama pull` line, Open Terminal) and re-checks by itself; Home shows a banner until the rewrite model answers; Rewrites say so instead of failing quietly; `docs/LOCAL-MODEL-GUIDE.md` is in the release zip and `install.sh` points to it. What is still open is the part below that downloads for the friend: a progress bar, the checksum check and resume, so nobody opens Terminal. Today `install.sh` does it in Terminal and needs Homebrew. A friend who unzips the app should see a first-run "Get ready" screen instead: install the speech engine, download the 574 MB speech model with a progress bar and the checksum check, then optionally install Ollama and the tidy-up model (7.6 GB) with its own progress. One action per screen, a short privacy line on each step ("this stays on your Mac"), and a two-segment progress bar across the setup (the pattern Wispr Flow uses on the phone, see `REFERENCE-WISPR-GRAMMARLY.md`). Resume if the download stops, and say plainly how much disk it takes before starting.

**10. Three ways to get Purrscribe: free local, monthly cloud, build it yourself (decided 11 Nov 2026; the cloud part is not built).** (1) Free, on your own Mac with your own local models, with a guide that connects every new user to the local AI (built, see idea 9). (2) A cloud plan paid monthly, for people with an older Mac, little disk or no wish to run models: speech and tidy-up run on a Ranklore server, and the money goes to Ranklore's Stripe account. (3) Build it yourself from the source on GitHub (documented in the README; needs the repository to be public with a licence). The Account tab already shows all three. What exists for (2): the plan card (Coming soon until a build is given a checkout link, `PURRSCRIBE_CHECKOUT_URL`) and a Stripe Checkout tool (`cloud/stripe/`, `docs/CLOUD-CHECKOUT.md`). What is missing, in order: the cloud service itself (a licence check and a server that runs Whisper and the tidy-up model; without it a buyer pays for nothing, so no build gets the link before it exists), a price that covers the server time, a Stripe key for the Ranklore account and the activated Customer Portal, and a guard on Ranklore's existing Stripe webhook (it sends its SEO welcome email on every completed checkout, so a Purrscribe buyer would get an SEO email). The cloud plan breaks the line "audio and text never leave the Mac", so it must be a separate, opt-in switch with the cost and the data path written next to it, and the free local app must keep working exactly as it does now. Cheapest first step: ask five friends what they would pay for, and count how many of them get stuck on the local install (the guide and the Help page may already remove most of the need).

## Not doing

- An account, a server, a subscription or cloud sync in the free local app (use a folder you choose). The monthly cloud plan is a separate, opt-in way to get Purrscribe: see idea 10.
- Recording the screen as video, logging individual keystrokes, or reading the clipboard's contents. (The deeper notes keep screen text, typing counts and finished lines, cleaned, and only if switched on.)
- Letting any automation publish, send, spend or change a live account on its own. A task Purrscribe creates only opens apps; anything bigger goes to an agent as a brief and waits for a yes.

## Before a public release

- **The name.** A product called PurrScribe AI already exists. Treat "Purrscribe" as a name collision to check: search the trademark registers (Singapore first, then wherever it will be sold), look at the app stores and the domain names, and decide whether to keep the name or change it before anything is sold or put on the App Store.
- **The wordmark font.** The cursive wordmark (`assets/brand/wordmark-purrscribe.png`, made by `scripts/art/make_wordmark.py`) is rendered from an Apple system font (SignPainter HouseScript Semibold). It is fine as a picture on this Mac, but it is not an open-licence font. Swap `FONT_PATH` in that script for an open-licence script font (Great Vibes, for example), run it again, and check the tilt and the margins before release.
