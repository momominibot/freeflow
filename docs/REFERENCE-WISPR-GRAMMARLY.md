# Reference notes: Wispr Flow (iPhone) and Grammarly (iPhone)

Prepared 2026-11-10 for the FreeFlow iPhone work. Public sources only. This is desk research from public pages: a live walk through both apps on a real iPhone has not been done yet, so UI details marked unverified below are still open. Nothing was installed, downloaded or signed in to. All wording below is my own summary; any quoted term is a few words at most.

## 0. How this was gathered, and what to distrust

- Read-only web research with web search and page fetch. Pages were read through a summarising fetch tool, so every number below is "as the summary reported it". Prices, ratings and word limits should be re-checked on the live page before they go into anything outward-facing.
- Reddit could not be reached by the search tool (blocked). I used Hacker News (via its public search API), Product Hunt threads, an AppleVis post, an iOS forum thread and App Store review themes instead.
- No YouTube transcripts were retrieved. There is no screenshot or video evidence here, so UI descriptions come from text only (vendor help pages, App Store text, write-ups).
- Several sources are competitors or affiliate blogs. They are marked "competitor" or "third party" and are only used as leads.

## 1. Sources

Core set (S1 to S9):

- S1 Wispr Flow help center, iPhone pages (vendor, primary):
  - Keyboard setup: https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone
  - First-run guide (desktop, iPhone, Android): https://docs.wisprflow.ai/articles/3152211871-setup-guide
  - App navigation (tabs, history, settings): https://docs.wisprflow.ai/articles/5096240724-navigating-the-wispr-flow-app-desktop-ios-and-android
  - Styles: https://docs.wisprflow.ai/articles/2368263928-how-to-setup-flow-styles
  - Hands-free: https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free
  - Command Mode: https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode
  - Snippets: https://docs.wisprflow.ai/articles/5784437944-create-and-use-snippets
- S2 Wispr Flow App Store listing (vendor, primary; privacy label is self-declared): https://apps.apple.com/us/app/wispr-flow-ai-voice-keyboard/id6497229487
- S3 Wispr Flow pricing page (vendor): https://wisprflow.ai/pricing
- S4 9to5Mac hands-on of the iPhone keyboard, June 2025, so early beta (press): https://9to5mac.com/2025/06/30/wispr-flow-is-an-ai-that-transcribes-what-you-say-right-from-the-iphone-keyboard/
- S5 User voices on Wispr (mixed quality):
  - Product Hunt iOS thread (about a year old): https://www.producthunt.com/p/wisprflow/wispr-flow-for-ios?page=2
  - AppleVis post (VoiceOver users): https://mail.applevis.com/comment/209687
  - Hacker News comments (via https://hn.algolia.com/api/v1/search?query=wispr%20flow%20ios&tags=comment); items quoted by id below, e.g. https://news.ycombinator.com/item?id=46824506 and https://news.ycombinator.com/item?id=48204030
  - Vendor blog on privacy: https://wisprflow.ai/dictation-blogs/is-wispr-flow-safe-security-and-privacy
- S6 Grammarly support pages (vendor, primary):
  - Keyboard overview: https://support.grammarly.com/hc/en-us/articles/360009187612
  - Why Full Access: https://support.grammarly.com/hc/en-us/articles/115000730091-Why-Grammarly-Needs-Full-Access-on-iOS
  - Tone detector: https://support.grammarly.com/hc/en-us/articles/360058226552
  - Generative AI on mobile: https://support.grammarly.com/hc/en-us/articles/24086943816845-How-to-use-Grammarly-s-generative-AI-on-my-mobile-device
  - Generative AI intro for iPhone and iPad: https://support.grammarly.com/hc/en-us/articles/22594181774605-Introducing-generative-AI-assistance-on-Grammarly-for-iPhone-and-iPad
- S7 Grammarly App Store listing (vendor, self-declared privacy label): https://apps.apple.com/us/app/grammarly-ai-keyboard-notes/id1158877342
- S8 User voices on Grammarly (anecdotal): Hacker News comments (https://hn.algolia.com/api/v1/search?query=grammarly%20keyboard%20ios&tags=comment), iOS 18 forum report https://talk.tidbits.com/t/ios-18-breaks-grammarly-keyboard/28926 (seen only as a search snippet, not opened), and App Store review themes in S7.
- S9 Apple, custom keyboard guide (primary, archived page, so older than iOS 18): https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html

## 2. Apple's rules that shape both apps (S9)

- A custom keyboard cannot use the microphone. This is why every iPhone dictation keyboard has to hand off to its main app, or lean on a recording session that the main app keeps open. Wispr's design (below) is a workaround for exactly this.
- Without Full Access ("open access") a keyboard is sandboxed: no network, no shared container with its app, no iCloud.
- With Full Access a keyboard can: use the network, share a container with its containing app, use the pasteboard, play audio, and sync via iCloud. Apple tells developers to treat that as a duty to keep typed and spoken data private and to tell users keystrokes are reachable.
- Secure text fields and phone-pad fields force the system keyboard back, whatever the app wants.
- Takeaway for FreeFlow: a fully on-device keyboard still needs Full Access if it shares an App Group container or the pasteboard with the app. The honest message is "so the keyboard can talk to FreeFlow on this phone", not "for the internet". (Needs a check against current Apple docs, since the page read is archived.)

## 3. A. Wispr Flow on iPhone

### 3.1 First-run onboarding, in order (S1 setup guide)

1. Install from the App Store and open the app once. The keyboard does not show in iOS Settings until the app has been opened.
2. Sign in (new accounts verify their email). An account is part of the flow. Needs a connection.
3. Turn on the Flow keyboard: Settings, General, Keyboard, Keyboards, add Wispr Flow from the third-party list.
4. Open Wispr Flow in that list and switch on Allow Full Access, then confirm the iOS warning.
5. Back in the app, the setup step advances once the app detects Full Access.
6. Practice cards: grant microphone access, switch to the Flow keyboard with the globe key, tap its mic, speak, tap the checkmark.
7. Finish: a few questions, data and language choices, notifications.
- In the app, the other tabs stay locked until the "Dictate in another app" step is done (S1 navigation page).
- Docs say the whole thing takes about a minute; the maker said a few minutes in-app (S5 Product Hunt).
- Troubleshooting the vendor documents: keyboard missing from Settings (open the app and tap the mic once, because an extension cannot raise permission prompts itself; or force-quit Settings); iOS switching back to the Apple keyboard after changing apps (tap the globe); microphone permission is separate from Full Access.

### 3.2 What "Allow Full Access" is for (S1, S9)

- Wispr says it is needed for transcription and for working across apps; it is separate from the microphone permission. Passwords are excluded and a privacy setting controls whether dictations are stored.
- Transcription is cloud-based (S1, S5, vendor blog), so for Wispr Full Access really does mean network. A Settings switch for Full Access also works as an off switch: turning it off pauses dictation without removing the keyboard.

### 3.3 Dictating inside other apps: the keyboard, the hand-off, the "flow bar" equivalent

- The iPhone has no Flow Bar. The Flow keyboard is the equivalent (S1 navigation page).
- Keyboard controls described: a mic button, a checkmark to finish, an orange warning triangle that opens error options, a settings button that opens a drawer, and a globe key. Where in-place dictation is not possible, a Start button replaces the mic. Number, phone and email style fields fall back to the system keyboard.
- Flow of a dictation (S1, S4): switch to the Flow keyboard with the globe, tap Start (or the mic). If no session is running, Flow opens the main app to record, then returns you to the app you were in, by itself if iOS allows or by a swipe back. If the return fails a "Flow is on" screen shows, and recording can resume if you get back within roughly 10 seconds. Tap the checkmark to end the take and the text is inserted at the cursor. Finishing without speaking inserts nothing.
- Session idea (S4, S5 Product Hunt maker reply): while the app holds a "Flow Session" open, the keyboard can start and stop dictation with no further app hop. In the June 2025 beta the user chose how long a session lasts (5 minutes, 15 minutes, an hour, or until closed). Whether those exact options still exist is not confirmed in the current help pages. A "background mic" setting in the app is the same idea; one user could not find docs for it.
- Interruptions: phone calls, audio interruptions and plugging or unplugging a headset or Bluetooth device stop the recording and it does not resume on its own. If the network drops mid-take, Flow keeps what is said afterward.
- Recent release notes on the App Store (S2): interrupted takes are saved to history with a notification and failed ones can be retried with one tap; a live timer shows in the Dynamic Island and lock screen (versions around 1.62); battery improvements in an earlier release.

### 3.4 Hands-free mode

- Not on iPhone. The help page says hands-free exists on Mac, Windows and Android; on iPhone you tap the mic, then the checkmark, so you still touch the screen (S1).
- The App Store text lists a "whisper mode" for quiet dictation (S2); no help page found that explains it.

### 3.5 Styles and tone

- Four styles exist: Formal, Casual, Very casual (personal chat only), Excited (work, email, other) (S1 styles page).
- Mac, Windows and Android pick a style per app category (Personal, Work messaging, Email, Other). iPhone uses a single default style ("Your default sound"), set in the Style tab, and the keyboard can override it. A keyboard override lasts 15 minutes after the take that used it, then reverts. On iPhone, messaging apps always drop the final period.
- Styles are mostly capitalisation and punctuation rules plus more exclamation marks for "Excited". Styles apply to English only. The help page does not say which plan includes Styles.
- Useful inference: an iOS keyboard cannot tell which app is in front, which is probably why iPhone has one default style rather than per-app categories. (My inference, not stated by Wispr.)

### 3.6 Dictionary and snippets

- The iPhone app has Home (statistics and history), Dictionary, Snippets, and Style (S1 navigation page). A side menu holds profile, settings and help.
- Dictionary: add a word by hand, or Flow adds names automatically when you correct a spelling (auto-add is a setting). A dictionary entry is a hint for recognition; a snippet is a guaranteed swap (S1 snippets page and a third-party note).
- Snippets: a spoken trigger plus the text it expands to. Say the trigger alone or inside a sentence and the saved text replaces it. Pick distinctive triggers; duplicates are refused. Personal snippets are on every plan, including the free one (S1).
- Shared dictionary and snippets for teams are a paid-plan feature (S3).
- On iPhone the "edit-based learning" that exists on desktop was missing at launch (S5 Product Hunt, about a year old).

### 3.7 Command mode (edit by voice)

- Off by default; turned on under an Experimental setting. Hold a shortcut, say an instruction such as rewrite what is selected or draft a reply, release. It sends the text box contents and selection with your instruction. Works on Mac and Windows only; Pro-only in practice (S1).
- On iPhone, in-place editing does not currently work and a spoken command can open a web search instead (S1). So there is no iPhone edit-by-voice to copy. Apple Dictation does have spoken editing commands (noted in a third-party comparison, https://zackproser.com/blog/wisprflow-vs-apple-dictation-2026).

### 3.8 Paywall and free limit

- The App Store listing says free with in-app purchases and a weekly word limit, without a number (S2). The help page says that on the free Basic plan dictation slows down and then blocks at the weekly maximum, until upgrade or weekly reset (S1 keyboard page). The pricing page says limited words per week and gives no number (S3).
- Numbers that appeared elsewhere: 2,000 words per week in the June 2025 hands-on (S4, now a year old); 1,000 per week on iPhone in a third-party review (unverified). Treat both as unconfirmed for today.
- Prices shown by the vendor: Pro $12 per user per month billed yearly or $15 monthly on the pricing page (S3); the iPhone listing shows Pro monthly $15.00, annual $143.99, weekly $4.49, student monthly $7.49 and student annual $72.00 (S2). Region and date may change these.
- What the paid tier adds per the vendor: no word limit and Command Mode (S1, S3). The help pages do not show what the upgrade screen looks like on iPhone, so the paywall layout itself is unverified.

### 3.9 What users praise

- Accuracy, cleaning up filler words and self-corrections, punctuation and formatting without special commands (S2 reviews, S5 Product Hunt, Hacker News).
- Clearly better than Apple dictation, say several commenters (S5).
- Dictionary for names and jargon, including developer terms dictated into coding tools (Hacker News).
- Works in any app from the keyboard, no separate app to open once a session is running (S5).
- Notes and history sync with the Mac, mixed-language switching (S5).
- Quick onboarding.

### 3.10 What users complain about

- App hopping and keyboard resets: the keyboard needs the app to start, iOS goes back to the Apple keyboard after switching apps, and the Flow keyboard does not hold typed letters so small fixes mean switching back and forth (S1, S2 reviews, S5).
- Cloud only: needs a connection and sends audio to servers; privacy-minded commenters dislike this (S5 Hacker News, vendor blog). Wispr's own privacy label lists identifiers and usage data used to track, and contact info linked to the user (S2, self-declared).
- No live text while speaking: the text appears only after you finish (S5 Hacker News and Product Hunt).
- Price against Apple's free dictation (S2 reviews, Hacker News); weekly word cap.
- Battery and privacy worry about the microphone staying on in a session (one App Store review, S2; a Reddit thread title was seen but not read, so battery impact is not established).
- Poor iPad keyboard support, a lost transcript in one review, support requests unanswered in one review (S2).
- VoiceOver speech gets recorded into the text; Apple's security prompts repeat; some unlabelled controls in Settings (S5 AppleVis).
- Odd microphone choice with AirPods (S5 Product Hunt); whispering confuses similar words (S5 AppleVis).
- Third-party claims that it takes screenshots are unverified and conflict with the vendor's text, which says the desktop context feature reads text from the active app, and that the iPhone keyboard uses context from the current text field with no such switch (vendor blog, S5).

## 4. B. Grammarly on iPhone

### 4.1 Keyboard setup (S6, S7)

- Install the Grammarly app, which carries the keyboard, an editor and a Safari extension. The listing and support page show iOS 17 and later (the listing text read as 17.4).
- Add the keyboard in iOS Settings (General, Keyboard, Keyboards, add Grammarly) and turn on Allow Full Access. Setup guides from third parties say the app's button sends you to Settings for this. Grammarly's own keyboard page does not list the Settings steps. Menu wording differs by iOS version.
- To bring it up, tap a text field, then use the globe key until the green Grammarly logo shows at the keyboard's top left.
- A companion app holds the personal dictionary, language, keyboard options, support and policy links.

### 4.2 Why Full Access, in Grammarly's words (S6)

- Needed so the keyboard can reach Grammarly's servers, which check the text. It says it checks only what is typed on the Grammarly keyboard, not text from other keyboards.
- Without Full Access the keyboard still types, but no checking or suggestions happen.
- It describes its exclusion of card numbers and passwords as best effort, not a guarantee, and suggests its other products for sensitive text.
- The keyboard's logo turns grey in sensitive fields (password, email, search), and a grey Wi-Fi mark means no connection.

### 4.3 How suggestions are shown on the keyboard (S6)

- Clear typos and common mistakes are fixed automatically, with a short note in the completions bar.
- Other suggestions appear in a suggestions bar above the keys: tap to accept or dismiss. A number beside the Grammarly icon says how many are waiting. Tapping the icon in the top left explains a suggestion in more detail.
- It supports emoji, emoji search and swipe typing. The listing mentions autocorrect, predictions and a one-handed mode.
- Underline colours: Grammarly colour-codes by category (red for correctness; sources agree on that). Which of green or purple is engagement versus delivery is contradicted between sources, and I found no source saying the iPhone keyboard shows underlines at all. Underlines are an editor and desktop idea; on the keyboard the bar is the main surface. Treat colours as unverified for iPhone.
- Turning off specific suggestion types (Oxford comma, passive voice) is paid-only (S6).

### 4.4 Tone detector and goals (S6)

- Tone is checked from the keyboard: write at least 90 characters, then tap the emoji or G icon at the keyboard's top left. (Older news coverage said 150; the support page's 90 is newer.) It can be switched off in the companion app under Keyboard. It is not available in the iPhone editor, only the keyboard on mobile.
- The support page does not describe what the result looks like (labels or emoji), so I cannot report that. The App Store text says the tone is detected for everyone and that changing the tone (tone transformations) is Premium.
- "Goals" (audience, formality, domain, intent) were not found on any iPhone page I could read. Unverified for iPhone.

### 4.5 Rewrite and generative AI buttons (S6)

- Select at least two words and an Improve button appears. Tap it for rewrite options: Improve, Rephrase, Shorten, Friendly. A double-arrow icon makes another version. To undo, tap the marked text.
- A fuller panel (iPhone and iPad) shows tone choices at the bottom, a box for your own prompt, and suggested prompts. Tapping a tone replaces the selected text; you can instead copy the revised text to use elsewhere.
- Free users have a daily prompt allowance; each typed or suggested prompt uses one; the number is not shown on the page I read.
- The listing also describes whole-message rewrites by length, tone and fluency, and voice dictation that removes filler words, saying audio is not stored (vendor claim). Grammarly now competes with dictation apps on this surface.

### 4.6 Free versus paid (S6, S7)

- Free: basic spelling, grammar and clarity help in the keyboard, tone detection, a limited number of AI prompts per day.
- Paid: advanced vocabulary and clarity suggestions, tone changes, higher AI allowance, turning individual suggestion types off. The App Store listing's in-app purchases (as read): monthly $29.99, quarterly $59.99, annual $139.99, and mobile-only plans at $17.99 monthly and $83.99 annual. Verify before quoting.
- Ratings as read: about 4.7 from roughly 228 thousand (S7); Wispr: about 4.8 from roughly 19 thousand (S2).

### 4.7 What users praise (S7 reviews)

- Easy setup, real-time corrections that help non-native and unsure writers, useful voice dictation, many languages, confidence boost.

### 4.8 What users complain about (S7, S8)

- Wrong flags on correct words; frequent upgrade prompts; core features limited without Premium; a Full Access requirement; updates that made the keyboard less stable.
- Reliability: an iOS 18 report that keys stopped registering when the keyboard was on; vendor release notes admit past fixes for text corruption when accepting suggestions during fast typing and smoother typing and swiping. Most lag reports I found were older or from Android, so current iPhone lag is not established.
- Privacy: commenters on Hacker News call any third-party keyboard with Full Access a keylogger by design and refuse to enable it; one dropped Grammarly on mobile because it needs a connection. These are opinions, not audits. A GitHub gist claiming trackers and keystroke handling was surfaced by search and is unverified.
- Keyboard feel: complaints about autocorrect, cursor movement and few suggestions compared with Apple's keyboard (older comments).
- Language support: one source said autocorrect and predictions are English only; the current listing mentions more languages. Treat as outdated or conflicting.

## 5. C. What FreeFlow iPhone could adopt (ranked by value)

Context checked in the repo: FreeFlow for iPhone today is an app (Whisper on the phone, no account, no server, works offline after the model download) with a Polish tab (Harper checker, Apple Intelligence rewrites, builder rewrites). The README lists the system keyboard, Command Mode, learning from corrections and Polish-while-typing as not built.

1. A system keyboard with a mic key that uses a short recording session kept alive by the main app, so the keyboard starts and stops dictation without a new app hop each time; the first dictation hops to the app once, and the checkmark ends the take.
2. A guided first run that sends the person to Settings, detects when the keyboard and Full Access are on, advances by itself, and ends with a practice field inside the app so the first success happens in about a minute.
3. A plain Full Access screen that says it is only so the keyboard can pass words to FreeFlow on this phone, that nothing is sent to a server, and what happens with it off (it still types, but no dictation); this wording must match what the code really does.
4. Visible recording state and session control: a Dynamic Island or lock-screen timer while a session is live, a choice of session length with an auto-off, and an obvious Stop, to answer the "is the mic always on" worry.
5. Never lose a take: keep the audio until the text is safe, save interrupted takes to History with a notification and a one-tap retry, and always put the result on the clipboard as well so paste works when insertion fails.
6. A slim suggestion strip on the keyboard from the on-device Harper checker, with a count badge, tap to accept, auto-fix of only clear slips with a visible note and an undo, and a greyed state in sensitive fields and when the check is off.
7. A select-text Improve key (two or more words) offering Improve, Rephrase, Shorten and Friendly with a "try another" arrow, undo, and a "copy instead of replace" choice, reusing the Apple Intelligence rewrites already in the Polish tab and saying so plainly when they are unavailable.
8. One default writing style (Formal, Casual, Very casual) set in the app with a keyboard override that lapses after a set time, done with simple capitalisation and punctuation rules so it needs no model, plus an on-demand tone check once the text is long enough.
9. Snippets next to the dictionary (say a trigger, get a saved block) and an offer to add a name to the dictionary when the person fixes its spelling, which also delivers the "learn from corrections" item already on the to-do list.
10. A live preview of the words as they are spoken, if the on-device speech engine can stream cheaply, since "text only appears after I stop" is the most repeated missing feature in user comments about Wispr.

Small extras worth noting: show a gentle "tap the globe to come back to FreeFlow" hint after a hand-off, since iOS resets the keyboard; fall back to the system keyboard in secure and number fields with a short message instead of a blank space; keep the keyboard thin and do heavy work in the app so typing never stalls.

## 6. What people complain about that FreeFlow can do better

- Cloud audio and keystrokes: Wispr is cloud-only and needs a connection; Grammarly sends typed text to servers and relies on Full Access. FreeFlow runs on the phone, has no account and works offline after the first model download. Say it in one line on the first screen, and make the App Store privacy label match (APP-STORE.md should be checked against the real code before claiming "no data collected").
- Account walls: Wispr asks for sign-in during first run. FreeFlow needs none.
- Caps and nags: Wispr has a weekly word limit and a subscription; Grammarly users cite frequent upgrade prompts and core features held back. FreeFlow can keep dictation, clean-up and Polish unlimited (APP-STORE.md already weighs a one-time purchase), and never interrupt typing with upsell cards.
- Lag and text corruption (Grammarly): keep suggestion checks off the typing path and debounced, never change text under the cursor without an undo, and show a clear "off" state instead of failing silently.
- False flags (Grammarly): keep Ignore and Add to dictionary one tap away, and keep the "why" visible.
- Hand-off friction and keyboard resets (Wispr): cannot be removed on iOS, but can be made less confusing with a clear "you are back, tap the globe" cue and a fast return; also avoid the "Flow is on" dead end by giving a visible manual return step.
- Microphone trust (Wispr): live timer, auto-off, and a one-line statement of when the mic is open.
- No live words (Wispr): idea 10 above.
- Accessibility (Wispr, AppleVis): test with VoiceOver on; when recording starts, mute or pause the screen reader's speech or play a short tone instead of speech so it is not transcribed; label all controls.
- Language switching: users like mixed-language handling; FreeFlow already keeps English words inside Chinese. Keep that visible as a selling point.
- Wispr's wording on iPhone Command Mode is "not working yet", so an edit-by-voice for selected text on iPhone (if built) would be ahead of the vendor, not behind.

## 7. Could not verify (read these before relying on any claim)

- Current Wispr session length options and whether the "background mic" setting still exists (only June 2025 and year-old comments).
- Exact Wispr free word limit on iPhone today (2,000 and 1,000 both appear; neither confirmed by a current vendor page).
- Wispr's Security Overview help page was returned by search but gave an error when fetched, so its Privacy Mode details came only from a search summary; the vendor blog was read and does not mention Privacy Mode.
- Wispr whisper-mode behaviour and how Styles map to plans.
- Grammarly tone result labels, Goals on iPhone, underline colours on iPhone, current keyboard language support, current iPhone lag status.
- All store prices, ratings and "what's new" lines were read through a summariser; verify live.
- Apple's keyboard page is archived and older than recent iOS releases; behaviour of Full Access, shared containers and the microphone should be rechecked in current Apple documentation or on a device before design decisions.
- The Hacker News comment texts were summarised from search results; I spot-checked two comment ids (the cloud-only comment and the no-live-transcript comment) and they matched, but did not read every thread in full.
- Nothing here was seen on a real screen. A short pass on a phone with both apps installed would settle the UI details (underline or bar look, tone result style, exact Wispr keyboard layout).
