# FreeFlow for people who build with AI

Most FreeFlow users talk to coding agents all day (Claude Code, Cursor, Codex, Copilot). This note says what FreeFlow does for them, what others already built, and what we took from them. Written 10 Nov 2026.

## What it does now

**Seven rewrites for builders** (Mac: Polish page and the menu bar "Rewrite selected text"; iPhone: Polish tab). Rough or spoken notes go in, text for an agent or a code host comes out.

| Rewrite | Gives you |
| --- | --- |
| Coding prompt | One goal sentence, then only the parts you really said: Context, Requirements, Constraints, Done when |
| Step-by-step plan | The goal, then small numbered steps in order, the check you named last |
| Bug report | Summary, What happens, What should happen, Steps to reproduce, Where, Error text |
| Commit message | Imperative summary line (50 characters, never over 72), a short "why" body if you gave a reason |
| Conventional commit | `type(scope): description`, optional body, `BREAKING CHANGE:` footer if you said something breaks |
| Pull request | Summary, Why, Changes, How to test, Notes for the reviewer |
| Code comment | One to three plain sentences, no comment marks |

The rules every one of them follows (this is the part the proven tools agree on):

- **Nothing invented.** A part you did not mention is left out, never guessed. No made-up file, function, library or command.
- **Your code survives character for character.** File names, paths, `snake_case` and `camelCase` names, calls like `save()`, `--flags`, links, versions, `#42`, error text and numbers. `RewriteGuard.codeTokens` finds them in your notes and a rewrite that loses or changes one is thrown away, not shown (a commit message may leave details out, but never invent them).
- **It writes up, it does not do.** A question in your notes stays a question in the prompt.
- Plain text with simple labels, so it pastes cleanly into a terminal, Cursor or a chat box.

**Say code the way it is written** (Mac and iPhone, fixed rules, works offline, no AI):

| You say | You get |
| --- | --- |
| camel case user profile card | `userProfileCard` |
| snake case max retry count | `max_retry_count` |
| kebab case (or dash case) order summary | `order-summary` |
| pascal case hot dog widget | `HotDogWidget` |
| constant case max retries | `MAX_RETRIES` |
| index dot ts | `index.ts` |
| src slash app slash main dot swift | `src/app/main.swift` |
| dash dash force | `--force` |

A case command only counts at the start of a sentence or clause, and the name stops at punctuation or a small joining word (and, then, is, to, with, in, for ...). So "I like camel case names" is left alone, and "camel case user name and then run it" gives `userName and then run it`. A name that has a joining word inside it (sign in) is cut there, so type that one.

The existing "Code" style for terminals and editors (identifiers kept exactly, no prose) and the dictionary already cover the rest.

## What others already built (checked 10 Nov 2026)

| Project | Licence | What it does that we looked at |
| --- | --- | --- |
| VoiceInk (the pinhosystems/VoiceInk fork was read) | GPL v3 | "Power Mode" presets by app: AI Coding Agent, Dev Environment, Messaging, Email. Built-in prompts include Task Prompt (speech into a clean brief for Claude Code, Cursor, Copilot Chat) and Code Comment |
| OpenLess (appergb/openless) | stated as fully open source | Headline "Structured" mode: ramble in, context, constraints and asks out. States the rule we also use: it never answers for you |
| voice-typed (saurabhrkp-fiftyfive) | MIT | Separate keys for verbatim, "new task" prompt, "follow-up" prompt and chat reply |
| Verba (talent-factory) | not checked | VS Code templates: Commit Message, Code Comment, Explain Code, Claude Code Prompt. Course correction ("no wait, Friday") |
| Axo, speech2ai (MIT); Promptimize (not checked) | mixed | A "Prompt Engineer" or "Coding Agent" mode that outputs a structured prompt |
| Wispr Flow (closed) | n/a | Variable recognition (camelCase, snake_case, acronyms, CLI commands), file tagging in Cursor and Windsurf chat |
| Superwhisper (closed) | n/a | Custom modes per app, answer coding agents by voice, commit messages and PR descriptions |
| Talon, Flit docs | n/a | The spoken formatter vocabulary: camel, snake, spinal or dash, smash, constant, title; "dash dash force" binds right |
| aicommits, OpenCommit | not checked | Commit formats: plain, conventional, conventional+body, gitmoji; 50-character subject |
| prompt-polish, HCGStudio/prompt-enhancer, Promptune (MIT); codyhxyz/prompt-optimizer (AGPL) | mixed | Prompt improvers. Shared lessons: polishing is mostly subtraction; never invent a file; unknowns become placeholders or open questions; goal first |

Official guidance we followed for the prompt shape: Anthropic's Claude Code best practices (name the file, describe the symptom, say what "fixed" looks like, give a check that passes or fails, point at an existing pattern, state a measurable target), Cursor's agent best practices (plan first, specific prompts, verifiable goals) and GitHub's Copilot prompt guide (goal first, then specifics, most important requirement first).

## What we copied, and what we did not

- **Copied the ideas, not the words.** We took the structure and method (goal first, only what was said, a check to run, code kept exactly, caller never answered for) and wrote every prompt fresh. VoiceInk is GPL v3, so none of its code or prompt text was used.
- **Made our own:** the guard. The others trust the model; FreeFlow checks the result and refuses a rewrite that lost a file name, flag or number.
- **Made our own:** it runs on the iPhone with Apple's on-device model, and on the Mac with the local model. No cloud, no key.

## Not built yet (and why)

- **One-step "speak a prompt"** (hold a key, talk, a structured prompt is typed). The dictation tidy-up has its own guard that expects the same words back, so a restructure needs a separate key and path. Today it is two steps: dictate, then pick Coding prompt (menu bar, or Polish tab).
- **File tagging and variable recognition from the editor** (Wispr Flow). Needs per-editor integrations; the dictionary and the case commands cover most of the value.
- **Answering a coding agent by voice** (Superwhisper's plugin for Claude Code and Codex). Possible later through an MCP tool or hook.
- **Reading the project's `CLAUDE.md` or `AGENTS.md`** to add conventions to a prompt (prompt-enhancer does this). Easy to add on the Mac when the folder is known.
