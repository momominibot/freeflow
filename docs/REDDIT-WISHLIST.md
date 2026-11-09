# What Reddit asks for in a dictation app

Searched 9 Nov 2026: r/WisprFlow, r/macapps, r/mac, r/MacOS, r/ClaudeCode, r/cursor, r/ClaudeAI, r/LocalLLaMA, r/ProductivityApps, r/ObsidianMD, r/alternativeto, plus the docs of the apps people name (Wispr Flow, Superwhisper, VoiceInk, MacWhisper, TypeWhisper, Handy, FluidVoice, Pipit, Voibe, Hushtype, OpenWhisper, Minutes). These are reported wishes and complaints from public posts, not measured demand.

Status column: **have** = FreeFlow already does it, **soon** = cheap and planned next, **later** = bigger job, **no** = against how FreeFlow works.

## Trust and reliability (the loudest group)

| Wish | Where it came from | FreeFlow |
|---|---|---|
| Never lose a dictation: if pasting fails the text waits somewhere ("Unsent text"), and the last one can be re-pasted | Hushtype, Minutes, WhisperTyping re-paste key, OpenWhisper "paste the original of the last dictation" | partly (Copy last result, History); soon: paste-last shortcut and unsent list |
| Text lands in the wrong place when you click away mid-dictation | r/cursor "Input misplacement", r/WisprFlow paste bugs | soon: remember the target app and copy instead of paste if focus changed |
| Restore my clipboard after pasting | OmniVox, OpenWhisper, Wispr docs | check and add as a switch |
| Retry a failed or poor transcription from saved audio | WhisperTyping, Minutes "Recovery" | have for kept recordings (compare engines); soon: retry button in history |
| Type like a keyboard in remote desktops, Citrix, VDI (pasting breaks there) | r/DictationTools guide on Wispr | later: keystroke typing mode per app |
| First word cut off when you press the key | Hushtype "keep the microphone ready", Pipit | later: optional pre-roll buffer |
| Escape cancels a recording | WhisperTyping, Hushtype | have (any key cancels) |
| Launch quietly in the menu bar, no window at boot | r/WisprFlow tray request | have |
| Slow or laggy app, forced extra clicks, language no longer auto-detected | r/WisprFlow "You are making a great product terrible" | have: Whisper stays loaded; language is explicit by design |

## Privacy and price

| Wish | FreeFlow |
|---|---|
| Fully on-device, no subscription, one price or free | have (this is the whole point) |
| Know exactly what leaves the Mac; per-app "keep no history" | have: nothing leaves; soon: per-app no-history |
| Cloud sync of history across devices, but optional | later: through a synced folder you choose, not a server |

## Writing quality

| Wish | FreeFlow |
|---|---|
| Cleanup (fillers, self-corrections "no wait, I mean") matters more than raw accuracy | have fillers and AI tidy-up; soon: "scratch that" and take-backs by rule |
| A creativity dial: let the AI rephrase and expand, not just transcribe ("set Wispr free") | soon: a fourth tidy-up level, Rewrite |
| Formality per app (formal, casual, very casual) | have per-app styles; soon: Wispr-style categories with a very casual option |
| Per-app profiles for language, engine and prompt | partly (styles, modes); soon: per-app language |
| Spoken punctuation, numbers and units written the way you type them | have punctuation rules; later: units |
| Whisper or quiet-room mode | partly (quiet gate); later: gain-lifting hush mode |
| Live text in the bar while you speak | later (needs a streaming engine) |
| Voice commands: new line, new paragraph, delete last word, undo that, press enter | have press enter and new line; soon: delete last word, scratch that |
| Edit selected text by voice | have (Command Mode) |

## Words and names

| Wish | FreeFlow |
|---|---|
| Bulk import and export of the dictionary, with misspelling aliases; import from another app | soon: import from text, CSV or JSON; export |
| Learn spellings from my corrections | have |
| Names read from the screen are often still wrong | have no screen reading; learning covers it |
| Search and sort the dictionary and snippets | soon |

## Developers dictating to Claude Code and Cursor

| Wish | FreeFlow |
|---|---|
| File names, paths and variable names must not be altered | have: Code style keeps identifiers; soon: add file names from chosen project folders to the vocabulary |
| Tag files by voice in Cursor chat | no (needs each editor's chat) |
| Per-app prompts: prose in a terminal, literal in a shell | have (styles and modes) |
| An MCP server so agents can read what I said | have for dictations; soon: the same for meeting notes |
| One long rambling prompt cleaned up before it reaches the terminal | have |

## Meetings

| Wish | FreeFlow |
|---|---|
| No bot joins the call; both sides recorded on-device | have (mic plus system audio) |
| Speaker labels | partly (You and Others); later: real speakers |
| Notes as plain Markdown into Obsidian or a folder I choose | partly (Markdown files); soon: choose the folder |
| Ask questions across all my meetings | soon: local AI over the notes |
| Action items and a summary template | summary exists; soon: an Action items section and templates |
| Watch a folder and transcribe whatever lands in it (voice memos) | soon |
| Calendar tie-in with a heads-up before a meeting | later: needs Calendar permission |

## History

| Wish | FreeFlow |
|---|---|
| Search, export (Markdown, text, JSON), calendar view | soon: search and export; later: calendar |
| Switch between the raw and the cleaned text | soon: both are already saved in history |
| Dark mode | the most repeated ask on r/WisprFlow (at least four threads). Done: dark royal purple, Settings > General > Appearance or the moon button |

## Reading list

- r/WisprFlow: "Dark & Command mode!", "When, for the love of God, will you get dark mode?", "What are some of the upcoming features?", "Set Wispr Flow free!", "Feature Request: remove AI polish and copy direct transcription".
- r/macapps: "Best FOSS macOS Dictation", "A Definitive Dictation App Comparison", EnviousWispr 2.4.3 notes on dictionary import.
- r/ClaudeCode: "What do you all use to dictate to Claude Code?"; r/cursor: "Voice Input for Cursor".
- Docs worth copying ideas from: TypeWhisper features, Hushtype "Never lose text", OpenWhisper History and Scratchpad, Wispr Flow "Use Flow with Cursor, VS Code".
