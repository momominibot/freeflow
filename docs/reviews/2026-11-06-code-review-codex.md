# Independent code review, Codex gpt-6-astra (read-only, all sources inline), 6 Nov 2026

The run hit its 15-minute alarm before writing its final ranked list, so this records the findings it reported in its progress notes and what was done about each. The full transcript is in `codex-code-run.log` (ignored by git).

| # | Finding (Codex) | Fix |
|---|---|---|
| 1 | The result queue preserves completion order, but it starts clipboard pastes asynchronously, so queued results can still overwrite each other. | `AppDelegate.pumpDeliveries` pastes one result at a time; `Inserter.paste` takes a completion that fires after the clipboard is restored (0.7 s); the next result starts only then. |
| 2 | Destructive suffix matches: "press enter" / "new line" / "new paragraph" matched inside ordinary sentences. | `SpokenCommands` now requires the command to start its own clause (start of dictation or after `. ! ? , ;`). "Type your password and then press enter." is plain text; tests added. |
| 3 | The Command Mode target can change between reading the selection and pasting. | `deliver` compares the frontmost app at paste time with the app recorded when the key was pressed; on a mismatch the result is copied and the pill says so. Applies to dictation too. This is exactly the failure seen live when the Codex app came to the front. |
| 4 | The rewrite guard accepts swapped payment amounts. | `looksLikeSameDictation` now requires every number in the rewrite to exist in the original and to appear in the same order; thousands separators are normalised. Tests: swapped amounts rejected, invented "3pm" rejected, 75000 vs 75,000 accepted. |
| 5 | The MCP script used Python 3.12-only f-string syntax while the installer's `/usr/bin/env python3` can resolve to 3.9. | Backslash moved out of the f-string; compiles on /usr/bin/python3 3.9.6 and 3.15; stdio harness re-run on 3.9. Input validation added for `=>`, newlines and `#` in words, corrections and cues. |
| 6 | The installer deleted the working app before validating its replacement. | `install.sh` stages to `/Applications/.FreeFlow.app.new`, strips quarantine, runs `codesign --verify --deep` and the app's `--test`, and only then swaps it in. |

Earlier design-stage opinions: Jev (jev-1.14.0) chose local AI as the default at 0.88, agreed a guard beyond the prompt was needed at 0.79, a separate Command Mode key at 0.69, usage sharing off by default at 0.88, and was lukewarm on files-versus-server for team sharing at 0.58 (kept: the team is small and files need no server).

Verdict after fixes: all six findings addressed and covered by `--test` or a harness; no FAIL item remains open. Not re-reviewed by Codex after the fixes.
