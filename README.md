# Purrscribe

*Purrscribe used to be called FreeFlow. The data folder (`~/Library/Application Support/FreeFlow`), the saved settings and parts of the code still use the old name for now.*

Dictation for macOS, made for you and your team, with a few cats keeping you company. Hold a key, talk, let go, and clean written text appears wherever your cursor is. It also writes down your calls, learns your words and, if you let it, notices the routines in your day and sets up the boring ones for you. The free version has no account, no word limit and no subscription, and audio and text never leave the Mac.

## Three ways to get Purrscribe

| | Free, on your own Mac | Cloud, monthly | Build it yourself |
|---|---|---|---|
| Cost | Free, no word limit | A monthly price, not set yet | Free |
| Who runs the models | Your Mac: Whisper for speech, Qwen in Ollama for the tidy-up | A Ranklore server (planned) | Your Mac |
| Your voice and text | Never leave the Mac | Would be sent to that server, as a separate opt-in switch with the data path written next to it | Never leave the Mac |
| How you get it | Download the installer, run `./install.sh --with-ai`, then follow the [local model guide](docs/LOCAL-MODEL-GUIDE.md) | Subscribe in Settings › Account | `git clone`, then `./build.sh` (see [Build](#build)) |
| State today | Works now | **Coming soon, nothing is on sale.** The checkout tool is ready (`docs/CLOUD-CHECKOUT.md`); the cloud service behind it is not built | Works now: the repository is public and the code is under the MIT licence |

The free local one is the whole app and it stays free. After someone downloads it, Purrscribe leads them to the local AI by itself: a banner on Home until the rewrite model is ready, the page **Help › The local AI (free, on your Mac)** with the steps and buttons for Ollama, the Account tab's "Ways to get Purrscribe" card, and [`docs/LOCAL-MODEL-GUIDE.md`](docs/LOCAL-MODEL-GUIDE.md), which is inside the download as well. Settings › General › **Cat size** (small, medium, large, shown while the cats are on) sets how big they are.

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

**Which key.** Settings › General › Talk key: Right Option, Fn / Globe, **Left Control**, Right Command or Right Control. A MacBook has no Right Control, so Left Control is the one to pick there. Fn is the Globe key on a Mac, and macOS can use it to switch the language or open emoji; if that gets in the way, choose another key (or set Keyboard › Press 🌐 key to › Do Nothing). With Left Control, any other key pressed while it is down cancels, so shortcuts such as Ctrl+C are safe; holding it while clicking or dragging starts a dictation.

Sessions can run 20 minutes. A tap under 0.3 s does nothing, so an accidental tap is harmless.

**Double tap to start (like Wispr Flow).** Settings › General › **Start and finish hands-free with › Double tap**: one quick tap of the talk key does nothing, two quick taps in a row start hands-free dictation, two quick taps finish it (one stray tap while listening is ignored, and holding the key for more than half a second also finishes, so you cannot get stuck), and holding the key still works as push-to-talk. The first tap keeps the recording open for about half a second so the second press carries on with the same recording; if no second tap comes it is dropped. It works with any talk key, and suits Fn / Globe, which is pressed for other things. If macOS still opens the emoji picker or Dictation when you press Fn, set Keyboard › **Press 🌐 key to › Do Nothing** (a system setting Purrscribe does not change for you).

**When the words do not reach a text box.** A dictation is always saved in your history. When Purrscribe can tell it did not arrive, a card appears in the bottom right corner with the words and **Copy**, **Paste again** and **Close** buttons. It is clickable without taking your keyboard focus, so Paste again types into the box you were in. It appears when you switched to another app before the words were ready, when Purrscribe is not allowed to type into apps, when the focus is on something that is not a text box (a file list, a button, the desktop), and when a readable text box did not change after the paste (checked twice, half a second apart). In web pages, in Electron apps such as Claude, Slack and VS Code, and in apps that do not describe their text boxes, the paste is trusted as before, since their text boxes do not report what is in them (Claude's reports one character whatever you type) and nothing can be checked there. Switch it off in Settings › General › Pop-up when words can't be typed.

### The look

Purrscribe has two colourways and a small family of cats. Headings are Newsreader and text is Manrope in both (open fonts, bundled in `assets/fonts`), and the name is set in Baskerville SemiBold Italic, slightly cursive but easy to read (it ships with macOS and iOS). An older tilted brush wordmark picture is still in `assets/brand/` (made by `scripts/art/make_wordmark.py`), but the apps no longer show it.

- **Two colourways.** Pick one in **Settings › General › Appearance › Colours**; the window, the bar, the cats, the toys and the Dock icon all change at once.
  - **Dreamy** (the default): the Rhythme theme, lavender paper, plum ink, Rhea the kitten and cats with lilac collars.
  - **Sunset**: for people who like cats and warm neutrals. Butter and cream paper, espresso ink, apricot and peach accents, a warm brown at night, and ginger, cream and black cats with coral collars.
- **Light and dark.** Each colourway has two looks. Dreamy's night room is deep royal purple with lilac ink; Sunset's is warm brown. The moon or sun button at the top right switches between them. Settings › General › Appearance also offers **Match my Mac**, which is the default. Every page colour has a light, a dark and a Sunset value in `Sources/Theme.swift` (`RT`, built with `Color.dyn`), so a new view that uses `RT.*` follows all four automatically. Never use `Color.white` or a hex for a surface. The painted pictures are drawn for pale paper, so in dark they sit on a pearly tile. The floating bar is night plum (night espresso in Sunset) in both, so it reads on any wallpaper.
- **Cute cats (the default Look).** The mascot is Rhea, the kitten from Rhythme, and the painted pictures, the little face on the bar, the menu bar icon, the Dock icon and the app icon are all her and her cat friends. **Settings › General › Appearance › Look** switches between *Cute cats* and the older *Pearly bubble* (the speech bubble with the kawaii face); the choice applies at once. The cat pictures are Rhythme's own paintings, copied into `assets/art/cats/` as small webp files by `scripts/art/make_cat_art.py` (it reads Rhythme's `assets/room/dream` folder, set `RHYTHME_DREAM` if yours is elsewhere), and `scripts/art/make_cat_icon.py` makes the app icons from the kitten head. On a face-sized surface the cat is a solid head with the eyes and mouth cut out, not floating ears, so it stays readable at 18 points.
- **The bar.** A small plum pill at the bottom of the screen. At rest it is a tiny sleepy face (switch it off in Settings). While you talk it shows a face whose mouth moves with your voice and live bars. While it works the dots bounce. Short messages ("Learned: Ranklor → Ranklore") appear in the same pill.
- **The window.** Purrscribe is a menu bar app: look for the little face at the top right of the screen (on a Mac with a notch it can hide behind it when the menu bar is crowded). Click it › **Open Purrscribe**, or open Purrscribe from Spotlight or Launchpad (it is in Applications) while it is running and the window appears. **Settings › System › Show Purrscribe in the Dock** keeps a Dock icon all the time that opens the window. The sidebar has nine pages: **Home** (a greeting, total words, words per minute and day streak in a side panel, your recent dictations with search, a "show what I said" switch for the tidied ones, and export to Markdown, text or JSON), **Meetings** (call and file notes), **Stats** (words this week, a day average, the streak, a rough time saved, a 14-day bar chart, the apps you talk in most), **Words** and **Phrases** (tabs All / Personal / Learned / Shared with team, search, A to Z or newest first, import from a text, CSV or JSON file or the clipboard, export, a dismissible banner), **Tone** (your own writing instructions), **Rewrites**, **Jots** and **Workday** (see below). At the bottom: **Share with your team**, **Settings** and **Help**. **Settings** opens as a dialog with its own sidebar: General (shortcuts, microphone, appearance (light, dark or match the Mac, the Look: cute cats or pearly bubble, the Colours: Dreamy or Sunset, and the cats on top of the window), languages, tidy-up, speech engine), System (launch at login, the bar, sounds, permissions), Calls (call detection), MCP (one tile per maker with its brand picture: Claude (Desktop and Code), ChatGPT (the app and Codex), Cursor, Gemini CLI, Doubao Work, VS Code, Hermes and any other app; click a tile and it copies exactly what that app expects, with the next steps beside it), Account (your name), Team and Data and Privacy (keep recordings, learning, open the data folder, delete history). The sidebar can be hidden with the button at the top left, and the account button at the top right opens Account. A small **Getting started** list under the pages (try meeting notes, hear the other people, write down a recording, connect your AI tools) ticks itself off and goes away when done. The window opens by itself the first time.
- **Jots.** Start a dictation with "note to self" (or "add this to my scratchpad") and the rest is saved as a note in `scratchpad/` instead of being typed into the app in front. Write, edit, copy and delete notes on the Jots page. Ordinary sentences that merely mention a scratchpad are never taken.
- **Team and Help.** Settings › Team picks the shared folder, copies an invite note (nothing is sent), and shows who shares their word counts. Help has the quick start, fixes for the usual problems (including the `sudo killall coreaudiod` one) and buttons for the log and data folders.
- **The menu.** Short on purpose: status, Open Purrscribe, Copy last result, Undo AI edit, Correct my last dictation, Settings, Quit. Permission fixes appear only when something is missing.

To check the look without showing anything on screen: `Purrscribe.app/Contents/MacOS/Purrscribe --render-ui <folder>` writes a PNG of every page and every state of the bar, light in the folder and dark in `<folder>/dark`. `FF_SHOT_WIDTH=860` draws them at the narrowest the window can be, and `FF_SHOT_COLOURWAY=sunset` draws the Sunset colours without changing your saved choice.

### The cats

Six cats live in Purrscribe: Mochi (cream), Mango (ginger), Pepper (black), Smoky (blue-grey), Snowy (white) and Cocoa (chocolate brown). Choose who lives with you in **Settings › General › Appearance › Your cats**: up to three at a time, and a tap on a cat brings it in or sends it away. They need the Cute cats look.

- **A transparent strip on top of the Studio window.** The cats do not live inside the app. They sit on a see-through strip along the top edge of the window, out on your desktop, as if the window frame were a shelf. The strip lets every click through to whatever is under it, except where a cat or a toy is. When there is no room above the window, the cats walk along its top bar instead.
- **Lazing about.** One cat is out and about: it walks, sits down to look at you, lies down for a lazy while and, when it is tired, curls up and sleeps. The other two lie where they lie, breathing slowly, and when the sleeper has had enough one of them gets up and takes over. Tap a lying cat and it gets up while the one that was out lies down in its place. Tap the cat that is out and it jumps and sends a heart.
- **Chasing the ball.** Pick the ball up, move it about, let go, and it flies. The cat runs after it, jumps, catches it, bats it away and goes again.
- **The wand with a ribbon.** Pick it up and the ribbon swings from the tip. The cat chases it, leaps for it and swats it.
- **Fish biscuits.** One drops onto the strip and the cat comes over and eats it.
- **Cleaning up poop.** A while after a biscuit the cat leaves a small pile. Tap the pile and it is cleaned up.
- **The toy box.** The toys are not lying around. They are in a tiny toy box in the sidebar: a ball, a wand and fish biscuits. Click a toy and it bounces up out of the window onto the strip. Click it again, or double-click it on the strip, and it goes back in the box.
- Left alone, the cat plays with the ball if it is out and has bursts of zoomies now and then.
- **Reduce Motion hides the cats.** When Reduce motion is on in macOS (System Settings › Accessibility › Display), nothing moves and no strip is shown. You can also switch them off in Settings › General › Appearance › Cats on top of the window.

The behaviour is plain arithmetic on the clock and the pointer, in `Sources/CatRunner.swift` (its checks run without a window in `FreeFlow --test`). The strip window is `Sources/CatPerch.swift`, and `Sources/CatRunnerSkin.swift` hands the cats their pictures and colours.

### Tone and Rewrites

- **Tone** (window › Tone): your own writing instruction for the AI clean-up, such as "Warm and brief. Use my first name." Give a mode to chosen apps, or switch one on for every other app. An app's own mode always wins. It tunes tone; the guard that rejects a rewrite that lost your words still applies.
- **Rewrites** (window › Rewrites): saved prompts you run on text you have selected in any app, from the menu bar menu › **Rewrite selected text**. Five come ready (shorter, fix grammar only, friendlier, more formal, bullet points); add your own. The result replaces the selection. Needs the local AI.

Both live in `modes.json` in the support folder.

### Polish: spelling, grammar, clearer wording and word swaps

What people love in Grammarly, kept on this Mac: nothing you write leaves it.

- **Polish page** (window › Polish): write or paste, and suggestions appear a moment after you stop. Each card shows the problem in its sentence, says why in plain words, and has the fix as a button (**Spelling**, **Grammar**, **Punctuation**, **Clarity**, **Style**; filter by kind). **Ignore** a suggestion or **Add to dictionary** for a name. **Fix 7 mistakes** takes every clear spelling, grammar and punctuation fix at once. Above the cards: word count, reading time, how easy it reads, and the tone it comes across in.
- **Rewrite it**: Fix mistakes, Make it clearer, Shorter, Rephrase, Friendlier, More professional, More confident. It uses the local AI, shows the result for you to **Use this**, **Try again** or **Copy**, and throws a rewrite away if it changed a number, one of your dictionary words or the language.
- **Find another word**: a word you keep using, with alternatives to copy (ranked by how close they are in meaning).
- **Anywhere in the Mac**: the menu bar menu has **Fix spelling and grammar in selected text** and **Rewrite selected text** (the seven modes above, then your saved Rewrites).
- **While you dictate** (Settings › Writing, off until you switch it on): **Fix clear slips in what I say** repairs a wrong a/an, a lowercase "I" and a doubled word. Spelling is left alone. **Spelling** chooses British (the default, used in Singapore), American or Australian.
- Your dictionary and your team's are never called mistakes, and URLs, e-mail addresses and symbol words such as `EMIS+` are skipped.

### For people who build with AI

Seven more rewrites sit under **For AI builders** (Polish page, and menu bar menu › Rewrite selected text): **Coding prompt**, **Step-by-step plan**, **Bug report**, **Commit message**, **Conventional commit**, **Pull request** and **Code comment**. Rough or spoken notes go in; plain text for an agent or a code host comes out. They only use what you said (a part you did not mention is left out), and a rewrite that lost or changed a file name, path, `snake_case` or `camelCase` name, `--flag`, link, version, error text or number is thrown away instead of shown.

You can also say code as it is written, with no AI and in both apps: "camel case user profile card" gives `userProfileCard` (also snake, kebab, pascal and constant case), "index dot ts" gives `index.ts`, "src slash app slash main dot swift" gives `src/app/main.swift`, "dash dash force" gives `--force`. A case command only counts at the start of a sentence, so "I like camel case names" is left alone.

What other voice tools already do, and what we took from them: `docs/AI-BUILDERS.md`.

The checker is [Harper](https://github.com/Automattic/harper) (Apache-2.0, by Automattic), compiled into the app, so it works offline and fast. `scripts/build-harper.sh` builds it once (needs Rust; `./build.sh` links it automatically when `native/harper/` exists and `./build.sh release` builds it if missing). Without it Purrscribe still builds and falls back to a smaller built-in rule list. Both engines run the same checks in `FreeFlow --test`. Licences: `ThirdPartyNotices.txt` (regenerate with `python3 scripts/gen-notices.py`).

### The pictures

Eight painted pictures of the mascot (waving with a microphone, reading, holding a note, with a paintbrush, chatting, hugging a cassette, watering a sprout, sleeping) show in the empty spots and headers of the window. They were made once with Seedream 5 pro in Rhythme's watercolour style by `scripts/art/run_art.py` (one guarded run, prompts in `scripts/art/prompts.json`), then `scripts/art/keypaper.py` took the paper backdrop out. The finished `assets/art/*.webp` are bundled by `build.sh`; the 1.6 MB originals in `assets/art/raw/` stay out of git. A missing picture falls back to the little face. With the cat Look on, the cat paintings replace them in the same spots (`assets/art/cats/` for Dreamy, `assets/art/sunset/` for Sunset, bundled to `Brand/art/cats` and `Brand/art/sunset`); the Look and Colours settings decide which set shows. A Sunset picture has the same file name as its Dreamy twin, and one that is missing falls back to the Dreamy one.

**The art generator scripts** (all in `scripts/art/`, all run from the repo root, all read Rhythme's cat paintings from `$RHYTHME_DREAM` and need Pillow with WebP; none of them calls an image model except `run_art.py`):

| Script | What it makes |
|---|---|
| `make_cat_art.py` | The square cat pictures for the window and the tall Rhea pictures, in `assets/art/cats/` |
| `make_walk_art.py` | The eight-frame side-view walk strips, one per cat (`walk-<cat>.webp`) |
| `make_runner_art.py` | The sitting and sleeping pictures of the cats on the strip (`runner-<cat>.webp`, `runner-sleep-<cat>.webp`) |
| `make_more_cats.py` | The six cats and the one command that redraws all their pictures: Smoky, Snowy and Cocoa are recolours of Rhythme's cats, in both colourways |
| `make_pet_items.py` | The toys: the ball, the fish biscuit and the pile (`toy-ball.webp`, `toy-fish.webp`, `toy-poop.webp`) |
| `make_sunset_art.py` | The Sunset set in `assets/art/sunset/`: the same cats with the lilac collars turned to coral |
| `make_wordmark.py` | The older cursive, tilted Purrscribe wordmark picture in `assets/brand/` (black on transparent). The apps now set the name in Baskerville SemiBold Italic instead |
| `make_cat_icon.py` | The app icons and the warm Sunset Dock icon |

### The logo

A painted speech bubble in Rhythme's pearly lilac, blush and peach, with a kawaii face and a glowing sound wave across it, on a rich lilac app-icon tile. The bubble came from the second round of Seedream pictures (`scripts/art/prompts-logo.json`, four candidates, the wave one won), keyed with `scripts/art/keypaper.py` into `assets/brand/logo-bubble.png`. `scripts/make_logo.py` composes the tile, mark and lockup from it (without a bubble file it falls back to `mascot.png` plus a drawn wave) and writes `assets/brand/` (logo-mark, logo-icon, logo-lockup, AppIcon.icns); `build.sh` bundles it. `scripts/make_logo_drawn.py` is the earlier version that draws the bubble in code.

### Meeting notes

Purrscribe watches which app is using the microphone (macOS 14.2 or later). When Zoom, Teams, FaceTime, Webex, a Slack huddle, or Google Meet / Teams / Zoom in Chrome, Edge or Arc starts a call, a card appears in the corner:

- **Start by itself** (default): a 10-second countdown, then notes start. **Not now** skips that call; pointing at the card pauses the countdown.
- **Ask me**: the card waits for you to tap **Take notes**.
- **Off**: nothing is watched. **Take meeting notes now** in the menu still works, for a call or a talk in the room.

While it runs, the bar shows "Meeting notes · 12:41". Audio is cut into 30-second pieces, each piece is written down by the same local engine, and the audio is deleted right away. The notes land in `~/Library/Application Support/FreeFlow/meetings/` as plain Markdown, with **You** and **Others** on separate lines (the others come from what the Mac plays, which needs *Screen & System Audio Recording*; without it only your side is written). If your microphone picks up the speakers, a line that repeats what the others just said is dropped. Notes stop about a minute after the call ends, or after 2 hours. The **Meetings** page lists them with Copy, Open and Delete.

**Summaries.** When a meeting ends, the local AI (the same Ollama model as clean-up) writes a summary, the decisions and the action items at the top of the note, and says it wrote them. Long meetings are noted in parts and merged, so nothing is cut off. It only uses what was said. Press **Summarise** on any note that has none. Needs Ollama; if it is not running, the note simply has no summary.

**Files.** Drop an audio or video file on the Meetings page (or **Choose file…**). ffmpeg (`brew install ffmpeg`) turns it into one-minute pieces, each piece is written down by the same engine, with minute stamps, and a summary follows. Quiet pieces are skipped. The result is a note like any other, marked as a recording.

Tell the others you are taking notes. Not done yet: a live transcript, joining from the calendar, speaker names beyond You and Others, Safari calls.

### Workday: notice routines, set up the boring ones

Off until you switch it on (Workday page). While on, Purrscribe looks at the front window every few seconds and keeps the app, a cleaned-up window title and the time: **no screenshots, no text from your screen**, nothing sent anywhere, deleted after 14 days. Password managers and private browser windows are never recorded; emails, links, keys and long numbers in titles are swapped for tags before anything is written; `workday/exclude.txt` hides any title that contains a word you list; the menu says when it is on; **Forget everything** deletes it.

From the notes (and from your dictations) it finds three kinds of routine and offers an action for each:
- **Apps you open first thing, at the same time, most days** → a scheduled task that opens them a few minutes earlier. **Add to my schedule** writes a small script and a macOS schedule file (`launchd`, the same job as cron, so it can open apps in your session; the cron form is shown). **Run a check** shows what it would open without opening anything. **Remove** deletes both. It only opens apps.
- **Back and forth between the same apps, again and again** (Chrome → Sheets → Chrome, 14 times) → a brief for an agent. **Copy brief** works with any agent; **Send to Hermes** appears when `~/.local/bin/hermes` (or the older `fleet-bridge`) exists and makes a card on the Hermes board for the agent you pick next to it (**Send to**: **Levi**, the default, who builds scripts and scheduled tasks, or **Eren**, who hands it to whoever fits). Both run on this Mac's own model, so the notes do not leave it. It uses `hermes kanban create`, with the brief passed on standard input; **Test the connection** makes a card nobody is assigned to and closes it again, so nothing runs. The brief names apps and counts only, never window titles.
- **A sentence you keep dictating** (the instructions you give your AI every time) → **Make a phrase**: a spoken cue that types it for you.

The MCP tool `workday_summary` gives an agent the minutes per app per day (names only). Switching the notes off stops recording at once.

#### Deeper notes: give an agent something to read

By default the notes hold no screen text and no typing. Three more switches under **Workday › Deeper notes**, each off until you turn it on, add them so an agent such as Hermes can find work you repeat and suggest scheduled tasks:

| Switch | What is kept | How |
|---|---|---|
| **Read the text on my screen** | The words on the front window, about every 2 minutes while you work | The window is captured and read on this Mac (Apple's text recognition); the picture is thrown away at once. Needs **Screen Recording** allowed for Purrscribe |
| **Note how I type** | Each minute: characters typed, characters deleted, seconds spent typing, and the lines you finished writing | It never logs keys. It looks at the text box you are in and counts what changed; a line counts as written once you leave it alone for a moment. A paste or a dictation (more than 40 characters at once) is not typing. Works in apps whose text boxes can be read |
| **Keep small pictures of the window too** | A small JPEG of the front window, for 3 days | For an agent that can look at images. Off unless you switch it on |

What protects you: emails, links, keys, long numbers and any line that mentions a password, a code, a token or a card are swapped for a tag **before** anything is written; password managers, terminals, private browser windows, Purrscribe itself, anything you list in `workday/exclude.txt`, and an idle or locked Mac are never read; the files are plain text in `~/Library/Application Support/FreeFlow/workday/detail/` (`screen-DATE.jsonl`, `typing-DATE.jsonl`, `pictures/`), deleted after 7 days (pictures after 3); **Open the folder** shows them and **Forget the deeper notes** deletes them at once; the menu says which parts are on. macOS may ask now and then whether to keep allowing screen recording.

**Ask Hermes for a closer look** sends a brief to the Hermes fleet that names those files (it carries none of their text) and asks for the repeated work found, what it costs in minutes a day, and proposals for cron tasks, phrases or agent skills that wait for your yes. **Copy the brief** does the same for any agent that can read files on this Mac. The MCP tool `workday_detail` returns the cleaned records directly. Sending takes a few seconds and does not freeze the window.

### Learn from my own typing

Off until you switch it on (Settings › Data and Privacy). When you type a name wrongly, backspace, and write it again, Purrscribe notices after you pause, and once it has seen a clear fix (a few letters off, not a half-deleted word) stand for 20 seconds it remembers the spelling the first time (in `learned.txt`, which you can read and edit; switch "Keep a clear fix the first time" off and every fix must be seen twice, and anything less clear always needs twice) and gives it to the speech engine as a hint. It compares the line you are on with how it looked a moment before; it keeps no text, only the spelling. Fixes into everyday words ("teh" to "the"), added words, rewrites, numbers and Chinese are ignored; a pause after deleting does not hide the fix; finishing a word you were still typing is not a fix. The **Learning** page shows fixes per 100 words, this week against last week, in plain words. It learns your vocabulary and your habitual slips; it does not retrain the speech model itself.


### Auto cleanup

| Level | What you get |
|---|---|
| None | The raw transcript |
| Light | Fillers removed, dictionary spellings applied. Rule-based, instant |
| **Medium** (default) | Light, then the local AI fixes grammar, applies your self-corrections ("budget 50K, actually make that 75K" becomes "budget 75K"), formats spoken lists, and matches the tone to the app: formal in Mail, casual in Slack and WhatsApp, untouched in code editors and AI chat apps |

The AI is Qwen 3.5 9B running in [Ollama](https://ollama.com) on your Mac. If Ollama is not running, Purrscribe quietly uses Light and tells you once. A guard rejects AI output that is not the same dictation (an answer instead of a clean-up, a preamble, a rewrite that lost half the words) and pastes the Light version instead. **Undo AI edit** in the menu copies what you actually said. Both versions are kept in `history.jsonl`.

Styles by app: `~/Library/Application Support/FreeFlow/styles.txt` (`bundle.id => formal | casual | neutral | code | plain`).

### It learns your words

Fix a word in the text Purrscribe typed and it remembers, with nothing else to do. This is lexical learning, the same idea as Volcengine's hotwords and self-learning: your own words, names and spellings are fed back to the engine. It does not retrain the speech model's weights.

How it works:

1. After Purrscribe types, it reads that one text box for up to a minute (needs Accessibility, skips password fields) only to see which words you changed. Nothing is kept except the word pairs, in `learned.txt` on this Mac.
2. A change counts only if it looks like a speech slip: not a rewrite of most of the text, not a number change, not a sentence-start capital. "Rank Lore" to "Ranklore", "emis" to "EMIS", "Shopfy" to "Shopify" count.
3. What you meant joins the prompt both engines get (Whisper's prompt, Qwen's context), so it is heard right next time. The pair also becomes an automatic swap once it has enough votes: a made-up word like "Ranklor" after 1 fix, a phrase or Chinese after 2, a real English word like "their" after 3, so one fix cannot rewrite normal text. Your own `dictionary.txt` always wins over a learned swap.
4. Where an app does not let Purrscribe read its text box, use **Learning > Correct my last dictation…**. That counts double, so a swap can start at once.

`learned.txt` is plain text. Delete a line to forget it, or use **Forget everything it learned**. Single fixes fade after about six months. Turn the whole thing off with **Learning > Learn from my corrections**.

### Dictionary and snippets

- `dictionary.txt`: one word or name per line teaches Whisper the spelling; `wrong => right` forces a swap. Or add it in **Dictionary** in the window.
- `snippets.txt`: `cue => expansion`, `\n` for a new line. Cues up to 60 characters, expansions up to 4,000. A dictation that is only the cue becomes the expansion exactly; a cue inside a sentence is replaced in place.

### Team

Pick any folder your whole team syncs (iCloud Drive, Dropbox, the NAS, a git checkout): **Team › Choose…** (also under Settings). Purrscribe keeps three files there and reads them on every dictation:

| File | Holds |
|---|---|
| `team-dictionary.txt` | Shared names, products, jargon, `wrong => right` swaps |
| `team-snippets.txt` | Shared cues: company address, support sign-off, booking link |
| `team-styles.txt` | Shared tone per app |

A person's own entry wins when it clashes with a team entry, so a team can share a base and everyone keeps their own overrides. `team-example/` in this repo is a starter set. Optional: **Share my word counts with the team** writes `usage/<name>.json` into the folder so everyone's totals can be shown; it is off by default.

### Connect to your AI apps (MCP)

Lets any agent that speaks MCP read your dictations and, if you switch the workday notes on, how your time went (app names and minutes only). **Settings › MCP** shows one tile per app with its brand picture (Claude and ChatGPT each get one tile with two small buttons: Desktop and Code for Claude, App and Codex for ChatGPT). Click a tile, or one of those buttons, and Purrscribe copies what that app expects: a shell command for Claude Code, Codex, Gemini CLI, VS Code and Hermes; a JSON entry for Claude Desktop, Cursor and any other app that reads an mcpServers list; the form values (name, type, command, arguments) for ChatGPT and Doubao Work. The picked app's next steps (where to paste it) show under the grid. For Claude Code the copied command is:

```bash
claude mcp add --scope user freeflow -- /usr/bin/env python3 "/Applications/Purrscribe.app/Contents/Resources/freeflow-mcp.py"
```

Tools: `search_history`, `recent_dictations`, `get_dictionary`, `get_snippets`, `get_usage`, `workday_summary`, `workday_detail`, `add_dictionary_word`, `add_snippet`. Standard-library Python, stdio, nothing leaves the Mac. Works with any MCP client that can run a local command.

How each app was checked, and the ones left out (Windsurf, ChatGPT chat, the consumer Doubao app), are in [docs/MCP-APPS.md](docs/MCP-APPS.md). The tiles come from `Sources/MCPApps.swift` (Claude Desktop and Claude Code share one tile, and so do the ChatGPT app and Codex, so no maker's logo shows twice), and `FreeFlow --test` keeps each copied text in the shape its app wants. The brand pictures are Simple Icons (CC0), made by `scripts/art/make_app_logos.sh`, plus the Hermes Agent icon, which Nous Research publishes under the MIT licence (its notice is `assets/brand/apps/NOTICE.txt` and it also ships inside the app); ChatGPT, Doubao and VS Code show the icon of the copy installed on the Mac, so none of those makers' artwork is shipped. The names and logos belong to their owners and appear only to say which app a tile is for.

## Speech engines (Whisper or Qwen3-ASR)

**Settings › Speech engine** switches between two engines. Both run on this Mac and nothing is uploaded.

- **Whisper large-v3-turbo** (default, MIT). Fast to start, ships with the install.
- **Qwen3-ASR 1.7B** (Apache-2.0, run with `mlx-qwen3-asr`). Lower word error on the Open ASR Leaderboard (5.76 against 7.83 for Whisper turbo, English average). Picking it the first time downloads about 5 GB and builds a private Python environment in `~/Library/Application Support/FreeFlow/engines/qwen` (script: `scripts/install-qwen-engine.sh`). Your dictionary is passed to it as context, so names are spelled your way.

To test on your own voice instead of trusting benchmarks: tick **Keep my recordings on this Mac** (off by default; by default the newest 100 are kept in `~/Library/Application Support/FreeFlow/takes`; under the switch you can choose how many to keep (25, 100, 500 or 2000), for how long (forever, 7, 30 or 90 days) and which folder, and recordings older than the days you chose are deleted. In a folder you chose, Purrscribe only ever counts, prunes or deletes the files it wrote itself, named like `20261109-185331-01-whisper.wav` and `.json`; your own files there are never touched, and for a folder other than the default give it to the script: `compare-engines.py <folder>`), dictate for a few days, then run

    ~/Library/Application\ Support/FreeFlow/engines/qwen/venv/bin/python scripts/compare-engines.py -o report.md

It runs every kept take through both engines side by side. For a ready-made test, read the 30 sentences in `docs/read-aloud-script.md` (English, Singapore English and Chinese mixed) and add `--script docs/read-aloud-script.txt`: the right answers are then known and both engines are scored per English word and Chinese character. Add `"truth": "what you actually said"` to a take's `.json` and it scores word error for both. **Delete recordings** in the same place removes them all.

**Mixed English and Chinese.** Pick Language › *English + Chinese (mixed)*. Whisper then detects per recording and the Qwen engine is told "Chinese", which keeps English words as spoken (left on auto-detect it once translated the Chinese half of a sentence into English). The clean-up AI is told never to translate, and its safety check now rejects any rewrite that loses the Chinese characters or turns English into Chinese. Tested on computer-generated speech only; real Singapore speech is the next test (use "Keep my recordings").

The Qwen package lists English, Chinese, Arabic, Dutch, French, German, Hindi, Italian, Japanese, Korean, Portuguese, Russian, Spanish and Turkish. For Malay, Indonesian, Tamil, Vietnamese and Thai the Qwen engine auto-detects and is untested here, so stay on Whisper for those.

## Install: free, on your own Mac (friends and teammates)

Purrscribe is free for friends. The installer in `dist` sets everything up on your own Mac with your own local models: the speech model, and with `--with-ai` the local AI for the tidy-up. No account, no bill, nothing uploaded. The paid cloud plan is not on sale yet and is optional; this free way stays.

1. Unzip `Purrscribe-<version>.zip`.
2. Run `./install.sh --with-ai`. It installs whisper.cpp with Homebrew, downloads the 574 MB speech model and verifies its checksum, copies the app to /Applications and clears the download flag so macOS opens it, then installs Ollama and downloads the 7.6 GB rewrite model (`qwen3.5:9b`). Plain `./install.sh` skips the last part; Purrscribe then still dictates, with rule-based clean-up only.
3. On first launch allow **Microphone** and **Accessibility**. Without Accessibility Purrscribe still transcribes and copies to the clipboard, but cannot press ⌘V for you.
4. Open Purrscribe › Settings › Team and Claude Code › Choose…

**Connected to the local model.** Everything about the local AI is written in [`docs/LOCAL-MODEL-GUIDE.md`](docs/LOCAL-MODEL-GUIDE.md), which sits next to `install.sh` in the zip: what the two helpers are, what disk and memory they need, the steps, a fix for each way it can go wrong, and how to use a different model. The app points to the same steps from inside: the Home page shows a banner ("Turn on free rewrites", "Start Ollama for rewrites" or "One download left") until the rewrite model answers (you can close it), **Help › The local AI (free, on your Mac)** shows what your Mac has and the next step with buttons (Get Ollama, Open Ollama, a copyable `ollama pull` line, Open Terminal) and checks again by itself every few seconds, Rewrites says "Rewrites need the local AI" with a **Set it up** button, and the menu bar has **Set up the local AI…**. It does not download anything for you: Ollama is Ollama's own installer and the model is 7.6 GB, so each step is one you start.

The app is signed with a development certificate, not a notarised Developer ID, which is why step 2 clears the quarantine flag. Notarising needs a paid Developer ID; `build.sh` already prefers one when it exists.

## Cloud plan (monthly, not on sale yet)

For people who would rather not run the models: speech and tidy-up would run on a Ranklore server for a monthly price, paid through a Stripe Checkout link whose payments go to Ranklore. The Account tab already shows the plan with **Coming soon**, and the Subscribe button appears only in a build made with `PURRSCRIBE_CHECKOUT_URL=https://…` (`build.sh` refuses anything that is not https). No build should carry that link until the cloud service exists, otherwise a buyer would pay for nothing. The checkout tool, the price lookup and what is still missing are in [`docs/CLOUD-CHECKOUT.md`](docs/CLOUD-CHECKOUT.md). It would break the line "audio and text never leave the Mac", so it is a separate opt-in switch with the data path written next to it, and the free local app keeps working exactly as it does now.

## Build

Building it yourself needs the source from GitHub, an Apple Silicon Mac with Xcode's command line tools, and Homebrew. It is free, and it gives you the same app as the download.

```bash
git clone https://github.com/momominibot/freeflow.git
cd freeflow
brew install whisper-cpp
./build.sh            # builds build/Purrscribe.app and runs the text checks
./build.sh install    # also copies to /Applications and launches
./build.sh release    # also makes dist/Purrscribe-<version>.zip with install.sh and the local model guide
scripts/build-harper.sh macos   # once, optional: the Harper grammar checker (needs Rust). Without it a smaller built-in checker is used
```

A build you make yourself runs on local models like the free download. After `./build.sh install`, set the models up with [`docs/LOCAL-MODEL-GUIDE.md`](docs/LOCAL-MODEL-GUIDE.md) (step 1 onward), or run `./install.sh --with-ai` from the `dist/Purrscribe-<version>/` folder that `./build.sh release` makes.

Model download (verify the checksum):

```bash
curl -L -o ggml-large-v3-turbo-q5_0.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
# sha256 394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2
```

## How it works

- `WhisperServer.swift` runs `whisper-server` (Homebrew `whisper-cpp`) on `127.0.0.1:8178` so the model stays loaded on the GPU. A 10 s clip transcribes in about 0.3 s.
- `Rewriter.swift` talks to Ollama on `127.0.0.1:11434` (`think: false`, temperature 0, keep-alive 60 min, warmed at launch). A 40-word clean-up takes about 0.8 s. See `docs/MEASUREMENTS.md`.
- `Input.swift`: talk-key and command-key monitors, 16 kHz WAV recorder, paste and ⌘C-with-clipboard-restore, selection reading through Accessibility.
- `Text.swift`: dictionary, rule-based clean-up, spoken commands. `Snippets.swift`: snippets, styles, the team folder. `Overlay.swift`: the bar. `Theme.swift`: Rhythme colours, fonts, controls. `Studio.swift`: the window and its pages. `AppDelegate.swift`: menu bar and the pipeline.
- Pipeline per dictation: Whisper → rules (or raw for None) → snippets → spoken commands → AI (Medium only, skipped when a snippet fired or the app's style is plain) → paste in spoken order.

## Checks

**One command checks everything:** `scripts/smoke.sh` builds, installs, then runs every function and ends with `SMOKE GREEN` or a list of what failed. `scripts/smoke.sh static` needs no app (build, unit checks, scripts, the stored voices, Whisper, the AI, the MCP server, and a picture of every page in light and dark). `scripts/smoke.sh live` drives the installed app: every page, button and setting through Accessibility, then dictation, "note to self", paste, a transform, edit by voice, a meeting with its summary and an audio file, all by speaking through the speakers into the microphone. It needs the speakers up and nobody typing: it brings TextEdit to the front several times and types into it, and refuses to type anywhere else. It saves your history, notes, dictionary, snippets, styles and settings first and puts them back at the end. `SMOKE_NARROW=1` also draws the narrowest window, `SMOKE_QWEN=1` also tries Qwen3-ASR. **`scripts/smoke-when-idle.sh`** waits until the Mac has had no keyboard or mouse use for 5 minutes and is not locked (it never unlocks it, and gives up at 6:00), then runs the whole thing and writes the log and a one-line result to `~/Library/Logs/FreeFlow/`; `ONLY="live_typing live_detail" scripts/smoke.sh live` runs just those live stages.

### The test voice

The smoke test speaks with a natural local voice (Kokoro-82M, Apache-2.0, no cloud) instead of the robotic macOS `say` voice, so Whisper hears something like a real person: one sentence at a time with breaths between them, an even level, and two speakers for the meeting. The voices Purrscribe keeps are listed in `assets/voices/voices.json`, each with a short alias, what it feels like and what it was used for:

| Alias | Voice | Feel |
|---|---|---|
| warm (default) | af_heart | warm, easy, the all-round pick |
| calm | af_nicole | soft and slow, close to the microphone |
| bright | af_bella | bright and lively |
| friendly | af_sarah | friendly, even, clear |
| narrator | am_michael | steady, a clear narrator |
| casual | am_adam | casual and relaxed |
| light | am_liam | light and younger |
| british-male | bm_daniel | British, measured |
| british-female | bf_emma | British, clear and polite |

A sample of each is in `assets/voices/samples/`. The model (`kokoro-v1.0.onnx` and `voices-v1.0.bin`, 350 MB) is kept in `~/Library/Application Support/FreeFlow/voices`, outside git. To speak a line: `python scripts/tools/speak.py OUT < lines.tsv` (name, voice or alias, text per line; `||` between speakers). `speak.py --voices` lists all 54 voices in the model, `--samples DIR` renders the kept ones. Its Python lives in Purrscribe too: `~/Library/Application Support/FreeFlow/engines/voice/venv` (126 MB, Python 3.12 with `kokoro-onnx`, `soundfile` and `numpy`). On a new Mac rebuild it with `uv venv --python 3.12 "$HOME/Library/Application Support/FreeFlow/engines/voice/venv"` and `uv pip install --python <that venv>/bin/python kokoro-onnx soundfile`, and copy the two model files into the voices folder (they come from the kokoro-onnx releases). `FF_VOICE_PY` points the test at a different Python.

Individual checks:

```bash
build/Purrscribe.app/Contents/MacOS/Purrscribe --test                 # text pipeline, meetings, modes, scratchpad and insights checks
build/Purrscribe.app/Contents/MacOS/Purrscribe --test-ai "um so we should budget 50k actually 75k" formal
build/Purrscribe.app/Contents/MacOS/Purrscribe --selftest clip.wav [en|auto|zh|...]
python3 scripts/freeflow-mcp.py --selfcheck
```

Live test without a human at the mic: `defaults write com.momominibot.freeflow debugTriggers -bool true`, then `FreeFlow --debug-post down|up|tap|command|lock|paste` while `say` plays through the speakers into the built-in mic. Make sure the target text field has keyboard focus (click in it, or ⌘A) and that nobody is typing: any key press while the key is held cancels the recording.

## Lessons that cost time

- **⌘V must be sent as the full physical sequence** (Command down, V down, V up, Command up, with the left-command device bit 0x08). A lone "V with Command flag" event is silently ignored by apps on macOS 26.
- **Do not use double-tap Option.** The Claude desktop app owns it (Quick Entry). Hands-free is Shift-while-holding instead.
- `--status` run from a shell reports the shell's permissions, not the app's. Test the installed app by using it.
- A window created by AppleScript (`make new document`) has no first responder until something focuses it; a paste into it goes nowhere.
- Whisper is told the language explicitly because auto-detect on short clips is shaky.
- The AI once added a "$" that was never spoken; the prompt now forbids adding symbols and the guard rejects rewrites that drift.
- **A small cat face needs a solid silhouette.** Ears drawn as separate shapes floated and looked broken at menu bar size; the head and ears are one shape with the eyes and mouth cut out (`.destinationOut` inside a `compositingGroup`). In the menu bar the cut-outs must be real transparency, not a colour.
- **Cat paintings need their bottom edge faded.** Cropping the Rhythme pictures left a hard line where the fur was cut; `scripts/art/make_cat_art.py` fades it, and `make_cat_icon.py` masks the white disc so fur does not spill past it.
- **Copy what the app expects, not one JSON for all.** Claude Code, Codex, Gemini, VS Code and Hermes take a shell command, Claude Desktop and Cursor want a JSON entry (Cursor also wants a type), ChatGPT and Doubao Work only have a form. Each is tested by a unit check (`mcp:` in `Purrscribe --test`).

## What people ask for

`docs/REDDIT-WISHLIST.md` lists what Reddit users say they want from a dictation app (searched 9 Nov 2026), with what Purrscribe already has and what is next. `docs/REFERENCE-WISPR-GRAMMARLY.md` is the flow of Wispr Flow and Grammarly on the phone, written from their public pages, help centres and store listings (not from a live walkthrough: the phone was not connected), with what Purrscribe matches and what it does not yet.

## Not done

- Ideas not built yet are in `docs/IDEAS.md` (a stats page with a speaking-speed gauge and streak calendar, tone by category, rewrites that run by themselves after dictation, a meeting list with questions across all your notes).
- The monthly cloud plan is not built. The Account tab shows it as Coming soon and a Stripe checkout tool is prepared (`docs/CLOUD-CHECKOUT.md`), but the service it would sell (a licence check and a server that runs speech and tidy-up) does not exist, so no build carries a Subscribe link and no one can pay yet. Its price is not set yet.
- Setting up the local models is guided but not one click: the **Help › The local AI** page and `docs/LOCAL-MODEL-GUIDE.md` give each step and a button for it, and you start the Ollama install and the 7.6 GB download yourself.
- No calendar connection. The free Purrscribe keeps everything on your device and has no account or subscription.- Learning is lexical (words and swaps). Retraining the speech model on your voice from your kept recordings and corrections is not built; it would be a separate, heavier step.
- Learning from fixes was tested live against TextEdit and by unit checks, not yet across browsers, Slack or Electron apps; where an app hides its text, use Correct my last dictation.
- Not tested with a human voice into the physical microphone; tests played speech through the speakers.

## Licence

The source code is under the [MIT licence](LICENSE), Copyright (c) 2026 Ranklore Pte Ltd.

The Purrscribe name, the logo and the cat artwork are not covered by it: [ARTWORK-AND-NAME.md](ARTWORK-AND-NAME.md) says what you can and cannot do with them. Parts made by other people keep their own licences: [ThirdPartyNotices.txt](ThirdPartyNotices.txt), [assets/fonts/LICENSE.txt](assets/fonts/LICENSE.txt) and [assets/brand/apps/NOTICE.txt](assets/brand/apps/NOTICE.txt).
