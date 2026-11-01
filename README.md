# FreeFlow

Free, offline push-to-talk dictation for macOS. Hold a key, talk, let go, and the cleaned-up text is typed into whatever app you are in. A stand-in for Wispr Flow with no word limit, no account and no subscription. Audio never leaves the Mac.

## Use it

| Do this | What happens |
|---|---|
| Hold **right ⌥**, talk, let go | Text appears at the cursor |
| While holding right ⌥, tap **⇧** | Locks hands-free. Let go and keep talking. Tap right ⌥ again to finish |
| Press **Esc** while recording | Cancels |
| Tap right ⌥ quickly by accident | Nothing happens |

Menu bar icon: talk key (right ⌥, Fn, right ⌘, right ⌃), language (English, auto, Chinese, Malay), filler-word removal, sounds, dictionary, history, open at login, word counts.

Text clean-up: removes um/uh, strips Whisper's invented "thank you" on silence, adds a leading space when you continue a sentence, restores your clipboard after pasting.

**Dictionary:** `~/Library/Application Support/FreeFlow/dictionary.txt` (menu: Edit dictionary). One word per line teaches Whisper the spelling; `wrong => right` forces a swap.

History: `~/Library/Application Support/FreeFlow/history.txt`. Logs: `~/Library/Logs/FreeFlow/`.

## How it works

- `WhisperServer.swift` runs `whisper-server` (Homebrew `whisper-cpp`) as a child process on `127.0.0.1:8178` so the model stays loaded on the GPU. Model: `ggml-large-v3-turbo-q5_0.bin` (574 MB) in `~/Library/Application Support/FreeFlow/models/`. A 10 s clip transcribes in about 0.3 s on an M5 Pro.
- `Input.swift`: global talk-key monitor (modifier keys), 16 kHz WAV recorder, paste.
- `Text.swift`: dictionary and clean-up. `Overlay.swift`: the pill. `AppDelegate.swift`: menu bar and state.

## Build

```bash
brew install whisper-cpp
./build.sh            # builds build/FreeFlow.app
./build.sh install    # also copies to /Applications and launches
```

Model download (verify the checksum):

```bash
curl -L -o ggml-large-v3-turbo-q5_0.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
# sha256 394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2
```

Sign with a real identity (build.sh picks the first one it finds) so macOS keeps the Microphone and Accessibility grants across rebuilds. Ad-hoc signing works but resets them every build.

First launch asks for **Microphone** and **Accessibility**. Without Accessibility FreeFlow still transcribes and copies to the clipboard, but cannot press ⌘V for you.

## Self-test (no microphone needed)

```bash
/Applications/FreeFlow.app/Contents/MacOS/FreeFlow --selftest clip.wav [en|auto|zh|ms]
```

## Lessons that cost time

- **⌘V must be sent as the full physical sequence** (Command down, V down, V up, Command up, with the left-command device bit 0x08). A lone "V with Command flag" event is silently ignored by apps on macOS 26.
- **Do not use double-tap Option.** The Claude desktop app owns it (Quick Entry) and opens a full-screen window that steals focus from the text field. Hands-free is Shift-while-holding instead.
- `--status` run from a shell reports the shell's permissions, not the app's. Test the installed app by actually using it.
- Test-harness note: a bare NSWindow with no Edit menu ignores ⌘V; give it one.
- Whisper is told the language explicitly (`en`) because auto-detect on short clips is shaky. Use the Language menu for Chinese or Malay.

## Not done

- Not tested with a human voice into the physical microphone; tests played speech through the speakers into the built-in mic and used simulated key presses.
- No cloud rewrite or tone change like Wispr's AI edits. It is transcription plus rule-based clean-up.
