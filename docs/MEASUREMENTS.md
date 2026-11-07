# Measurements (M5 Pro, 48 GB, macOS 26.5, 6 Nov 2026)

| What | Result |
|---|---|
| Whisper large-v3-turbo q5_0 via whisper-server, 10 s clip | about 0.3 s (from the 1 Nov build) |
| Local AI clean-up, qwen3.5:9b via Ollama, model already loaded, 40-word dictation with a self-correction | 0.75 s raw API, 0.85 s through the app (`--test-ai`) |
| Same, 25-word chat message, casual style | 0.79 s |
| First call after the model was unloaded (Ollama idle timeout) | 6.5 s, of which 5.9 s is model load. The app warms the model at launch and every 25 min with keep_alive 60 min, so this should only happen after a reboot. |
| Prompt quality | Self-corrections applied ("50K actually 75K" -> "75K"; "Friday no wait Thursday" -> "Thursday"), spoken "first, second, third" became a numbered list. One early run added a "$" that was not spoken; the prompt now forbids adding symbols and the same input came back as "75K". |
| Guard | `Rewriter.looksLikeSameDictation` rejects an answer instead of a clean-up, empty output, preambles ("Here is..."), and rewrites that keep under half the content words or change length by more than 2.2x / 0.3x. Then the rule-based text is pasted instead. |

Decision taken from these numbers: Medium (AI) clean-up is the default. Light (rules) remains one menu click away and is the automatic fallback.
