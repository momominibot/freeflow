# FreeFlow

Free, offline dictation for macOS that does what Wispr Flow does, for you and your team. Hold a key, talk, let go, and clean written text appears wherever your cursor is. No account, no word limit, no subscription. Audio and text never leave the Mac.

## Use it

| Do this | What happens |
|---|---|
| Hold **right ⌥**, talk, let go | Cleaned-up text appears at the cursor |
| While holding right ⌥, tap **⇧** | Locks hands-free. Let go and keep talking. Tap right ⌥ again to finish |
| Select text, hold **right ⌃**, say "make this shorter", let go | **Command Mode**: the selection is replaced with the edited version |
| Hold right ⌃ with nothing selected, say "reply saying I'll be there at 3" | The AI drafts it from the text around your cursor and pastes it |
| Say "**press enter**" at the end | Pastes, then presses Return (chat apps) |
| Say "**new paragraph**" | A blank line |
| Say a **snippet cue** ("my calendar link") | Types the saved expansion |
| Press **Esc** while recording | Cancels. Typing any other key while holding also cancels (you were using a shortcut) |

Sessions can run 20 minutes. A tap under 0.3 s does nothing, so an accidental tap is harmless.

### Menu bar

Talk key (right ⌥, Fn, right ⌘, right ⌃) · Command Mode key · Language (English, auto, Chinese, Malay, Indonesian, Tamil, Hindi, Japanese, Korean, Spanish, French, German, Vietnamese, Thai) · Auto cleanup level · filler removal · sounds · Teach a word · dictionary, snippets, styles · history · Team · Connect to Claude Code · usage (words today, all time, top apps) · Undo AI edit.

### Auto cleanup (like Wispr's)

| Level | What you get |
|---|---|
| None | The raw transcript |
| Light | Fillers removed, dictionary spellings applied. Rule-based, instant |
| **Medium** (default) | Light, then the local AI fixes grammar, applies your self-corrections ("budget 50K, actually make that 75K" becomes "budget 75K"), formats spoken lists, and matches the tone to the app: formal in Mail, casual in Slack and WhatsApp, untouched in code editors and AI chat apps |

The AI is Qwen 3.5 9B running in [Ollama](https://ollama.com) on your Mac. If Ollama is not running, FreeFlow quietly uses Light and tells you once. A guard rejects AI output that is not the same dictation (an answer instead of a clean-up, a preamble, a rewrite that lost half the words) and pastes the Light version instead. **Undo AI edit** in the menu copies what you actually said. Both versions are kept in `history.jsonl`.

Styles by app: `~/Library/Application Support/FreeFlow/styles.txt` (`bundle.id => formal | casual | neutral | code | plain`).

### Dictionary and snippets

- `dictionary.txt`: one word or name per line teaches Whisper the spelling; `wrong => right` forces a swap. Or use **Teach a word…** in the menu.
- `snippets.txt`: `cue => expansion`, `\n` for a new line. Cues up to 60 characters, expansions up to 4,000. A dictation that is only the cue becomes the expansion exactly; a cue inside a sentence is replaced in place.

### Team

Pick any folder your whole team syncs (iCloud Drive, Dropbox, the NAS, a git checkout): **menu bar › Team › Choose team folder**. FreeFlow keeps three files there and reads them on every dictation:

| File | Holds |
|---|---|
| `team-dictionary.txt` | Shared names, products, jargon, `wrong => right` swaps |
| `team-snippets.txt` | Shared cues: company address, support sign-off, booking link |
| `team-styles.txt` | Shared tone per app |

A person's own entry wins when it clashes with a team entry, the same rule Wispr uses. `team-example/` in this repo is a starter set. Optional: **Share my word counts with the team** writes `usage/<name>.json` into the folder so the Team menu shows everyone's totals; it is off by default.

### Connect to Claude Code (MCP)

Like Wispr's connector, but local and for your dictations. **Menu › Connect to Claude Code** copies the command:

```bash
claude mcp add --scope user freeflow -- /usr/bin/env python3 "/Applications/FreeFlow.app/Contents/Resources/freeflow-mcp.py"
```

Tools: `search_history`, `recent_dictations`, `get_dictionary`, `get_snippets`, `get_usage`, `add_dictionary_word`, `add_snippet`. Standard-library Python, stdio, nothing leaves the Mac. Works with any MCP client that can run a local command.

## Speech engines (Whisper or Qwen3-ASR)

Menu bar › **Speech engine** switches between two engines. Both run on this Mac and nothing is uploaded.

- **Whisper large-v3-turbo** (default, MIT). Fast to start, ships with the install.
- **Qwen3-ASR 1.7B** (Apache-2.0, run with `mlx-qwen3-asr`). Lower word error on the Open ASR Leaderboard (5.76 against 7.83 for Whisper turbo, English average). Picking it the first time downloads about 5 GB and builds a private Python environment in `~/Library/Application Support/FreeFlow/engines/qwen` (script: `scripts/install-qwen-engine.sh`). Your dictionary is passed to it as context, so names are spelled your way.

To test on your own voice instead of trusting benchmarks: tick **Keep my recordings on this Mac** (off by default; the newest 100 are kept in `~/Library/Application Support/FreeFlow/takes`), dictate for a few days, then run

    ~/Library/Application\ Support/FreeFlow/engines/qwen/venv/bin/python scripts/compare-engines.py -o report.md

It runs every kept take through both engines side by side. For a ready-made test, read the 30 sentences in `docs/read-aloud-script.md` (English, Singapore English and Chinese mixed) and add `--script docs/read-aloud-script.txt`: the right answers are then known and both engines are scored per English word and Chinese character. Add `"truth": "what you actually said"` to a take's `.json` and it scores word error for both. **Delete saved recordings** in the same menu removes them all.

**Mixed English and Chinese.** Pick Language › *English + Chinese (mixed)*. Whisper then detects per recording and the Qwen engine is told "Chinese", which keeps English words as spoken (left on auto-detect it once translated the Chinese half of a sentence into English). The clean-up AI is told never to translate, and its safety check now rejects any rewrite that loses the Chinese characters or turns English into Chinese. Tested on computer-generated speech only; real Singapore speech is the next test (use "Keep my recordings").

The Qwen package lists English, Chinese, Arabic, Dutch, French, German, Hindi, Italian, Japanese, Korean, Portuguese, Russian, Spanish and Turkish. For Malay, Indonesian, Tamil, Vietnamese and Thai the Qwen engine auto-detects and is untested here, so stay on Whisper for those.

## Install (teammates)

1. Unzip `FreeFlow-<version>.zip`.
2. Run `./install.sh` (adds `--with-ai` to also install Ollama and the 7.6 GB AI model). It installs whisper.cpp with Homebrew, downloads the 574 MB speech model and verifies its checksum, copies the app to /Applications and clears the download flag so macOS opens it.
3. On first launch allow **Microphone** and **Accessibility**. Without Accessibility FreeFlow still transcribes and copies to the clipboard, but cannot press ⌘V for you.
4. Menu bar › Team › Choose team folder.

The app is signed with a development certificate, not a notarised Developer ID, which is why step 2 clears the quarantine flag. Notarising needs a paid Developer ID; `build.sh` already prefers one when it exists.

## Build

```bash
brew install whisper-cpp
./build.sh            # builds build/FreeFlow.app and runs the text checks
./build.sh install    # also copies to /Applications and launches
./build.sh release    # also makes dist/FreeFlow-<version>.zip with install.sh
```

Model download (verify the checksum):

```bash
curl -L -o ggml-large-v3-turbo-q5_0.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
# sha256 394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2
```

## How it works

- `WhisperServer.swift` runs `whisper-server` (Homebrew `whisper-cpp`) on `127.0.0.1:8178` so the model stays loaded on the GPU. A 10 s clip transcribes in about 0.3 s.
- `Rewriter.swift` talks to Ollama on `127.0.0.1:11434` (`think: false`, temperature 0, keep-alive 60 min, warmed at launch). A 40-word clean-up takes about 0.8 s. See `docs/MEASUREMENTS.md`.
- `Input.swift`: talk-key and command-key monitors, 16 kHz WAV recorder, paste and ⌘C-with-clipboard-restore, selection reading through Accessibility.
- `Text.swift`: dictionary, rule-based clean-up, spoken commands. `Snippets.swift`: snippets, styles, the team folder. `Overlay.swift`: the pill. `AppDelegate.swift`: menu bar and the pipeline.
- Pipeline per dictation: Whisper → rules (or raw for None) → snippets → spoken commands → AI (Medium only, skipped when a snippet fired or the app's style is plain) → paste in spoken order.

## Checks

```bash
build/FreeFlow.app/Contents/MacOS/FreeFlow --test                 # text pipeline, 28 checks
build/FreeFlow.app/Contents/MacOS/FreeFlow --test-ai "um so we should budget 50k actually 75k" formal
build/FreeFlow.app/Contents/MacOS/FreeFlow --selftest clip.wav [en|auto|zh|...]
python3 scripts/freeflow-mcp.py --selfcheck
```

Live test without a human at the mic: `defaults write com.momominibot.freeflow debugTriggers -bool true`, then `FreeFlow --debug-post down|up|command|lock|paste` while `say` plays through the speakers into the built-in mic. Make sure the target text field has keyboard focus (click in it, or ⌘A) and that nobody is typing: any key press while the key is held cancels the recording.

## Lessons that cost time

- **⌘V must be sent as the full physical sequence** (Command down, V down, V up, Command up, with the left-command device bit 0x08). A lone "V with Command flag" event is silently ignored by apps on macOS 26.
- **Do not use double-tap Option.** The Claude desktop app owns it (Quick Entry). Hands-free is Shift-while-holding instead.
- `--status` run from a shell reports the shell's permissions, not the app's. Test the installed app by using it.
- A window created by AppleScript (`make new document`) has no first responder until something focuses it; a paste into it goes nowhere.
- Whisper is told the language explicitly because auto-detect on short clips is shaky.
- The AI once added a "$" that was never spoken; the prompt now forbids adding symbols and the guard rejects rewrites that drift.

## Not done

- Notetaker (meeting recording), mobile apps, Voice Profile and Perplexity search are Wispr features FreeFlow does not have.
- Auto-learning a word when you correct it by typing is not built; use Teach a word.
- Not tested with a human voice into the physical microphone; tests played speech through the speakers.
