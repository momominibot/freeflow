# Set up Purrscribe's local models (free)

Purrscribe is free when it runs on your own Mac. It uses two small helpers that also run on your Mac, so nothing you say or write is uploaded.

| Helper | What it does | Needed? |
|---|---|---|
| Speech model (Whisper) | Turns your voice into text | Yes. Without it there is no dictation. |
| Rewrite model (Qwen, run by Ollama) | Tidies grammar and lists, writes in the tone of the app you are in, Edit by voice, the Polish rewrites, meeting-note summaries | No, but it is worth having. |

Without the rewrite model Purrscribe still dictates. The tidy-up falls back to rules (fillers and spelling), and the parts listed above that need the AI tell you so instead of failing quietly.

## What you need

- A Mac with Apple Silicon (M1 or newer) on macOS 13 or later. The installer refuses Intel Macs.
- [Homebrew](https://brew.sh), which the installer uses for the speech engine.
- About 8.3 GB of free disk: 0.57 GB for the speech model and 7.6 GB for the rewrite model.
- Memory: we tested on a Mac with 48 GB. The rewrite model is a 7.6 GB file that has to fit in memory while it works, so on a Mac with 8 GB expect it to be slow or to crowd out other apps. 16 GB or more is the comfortable range. That last part is our estimate, not something we measured.

## The quickest way: one command

Unzip the download, open Terminal in that folder and run:

```bash
./install.sh --with-ai
```

It installs the speech engine and model (and checks the model's checksum), copies Purrscribe to Applications, installs Ollama, starts it, and downloads the rewrite model. Leave it to finish: the rewrite model alone is a 7.6 GB download.

Already ran `./install.sh` without `--with-ai`? Run it again with the flag, or follow the steps below.

## Step by step, if you already have Purrscribe

### 1. Check the speech part

Purrscribe shows "Ready" at the bottom of its sidebar when the speech engine is running. If it does not:

```bash
brew install whisper-cpp
ls ~/Library/Application\ Support/FreeFlow/models/
```

You should see `ggml-large-v3-turbo-q5_0.bin` (574 MB). If it is missing, run `./install.sh` from the download folder, which fetches it and verifies it.

### 2. Install Ollama

Either download the app from [ollama.com/download](https://ollama.com/download), or use Homebrew:

```bash
brew install ollama
```

### 3. Start Ollama

Open the Ollama app, or if you used Homebrew:

```bash
brew services start ollama
```

Purrscribe looks for Ollama at `127.0.0.1:11434`, which is Ollama's normal address. If you have changed Ollama's address, Purrscribe will not find it.

### 4. Download the rewrite model

```bash
ollama pull qwen3.5:9b
```

This is the model Purrscribe is built and tested with. It is a 7.6 GB download, so do it on a good connection.

### 5. Check it worked

```bash
ollama list
```

`qwen3.5:9b` should be in the list. In Purrscribe, open Help › Set up the local AI and press Check again, or just talk: the first rewrite takes a few seconds while the model loads, and then Purrscribe keeps it ready for an hour after you last used it.

## If something is off

| You see | What it means | What to do |
|---|---|---|
| "Local AI not running · using rule-based clean-up" | Ollama is not running | Open the Ollama app, or `brew services start ollama` |
| "Rewrites need the local AI" or "Command Mode needs the local AI" | Same | Same |
| Ollama is running but the AI stays off | The model is not downloaded | `ollama pull qwen3.5:9b` |
| The first rewrite is slow, later ones are quick | The model is loading into memory | Normal. It stays loaded for an hour after use |
| Everything is slow | Not enough free memory for a 7.6 GB model | Close big apps, or use the rules-only tidy-up (Settings › Tidy-up › Light) |
| "Ready" never appears | The speech engine is not running | Step 1 above |

For reference, on a Mac with an M5 Pro and 48 GB, a 40-word tidy-up took about 0.8 seconds (`docs/MEASUREMENTS.md`). Older or smaller Macs will be slower. We have not measured them.

## Using a different model

Purrscribe uses `qwen3.5:9b` unless you pick another model you already have in Ollama, on the Help › Set up the local AI page. Other models work only as far as Ollama can run them. We have not tested the quality or the speed of any of them, so if the tidy-up gets worse, switch back.

## Taking it off again

```bash
ollama rm qwen3.5:9b
brew services stop ollama
```

That gives back the 7.6 GB. Purrscribe goes back to the rules-only tidy-up.

## Optional: a second speech engine

Purrscribe can also use the Qwen3-ASR speech engine (about 5 GB) as an alternative to Whisper. It is optional and lives in `scripts/install-qwen-engine.sh`. The README explains when it helps.

## Rather not run models yourself?

There are three ways to get Purrscribe: free on your own Mac (this guide), a monthly cloud plan for people who do not want to run models, and building it yourself from the source on GitHub. The README has all three side by side.
