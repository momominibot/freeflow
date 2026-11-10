# FreeFlow for iPhone

The phone version of FreeFlow: tap (or hold) the button, talk, and the words are written on the iPhone and copied, ready to
paste anywhere. No account and no server. After the speech model has been downloaded once it works with no connection.

## What it does today (version 0.1)

- Speech to text on the iPhone with Whisper (WhisperKit, MIT). Fast (base), Balanced (small, the default) or Best
  (large v3 turbo, about 626 MB, the one for mixed English and Chinese). Language: English, Chinese (keeps English words) or detect.
- The same clean-up as FreeFlow on the Mac: it is the Mac app's own `Sources/Text.swift`, compiled into this app. Your
  dictionary (words and `wrong => right` swaps), taking out "um" and "uh", dropping the "thank you" a silent take produces,
  and "new paragraph". The words in the dictionary are also given to the speech model as a spelling hint.
- **Polish** (second tab), the Grammarly-style part, all on the iPhone: write or paste and get spelling, grammar, punctuation,
  clarity and style suggestions with one-tap fixes (the same Harper checker as the Mac app, `Sources/Polish.swift`), Fix all,
  Ignore, Add to dictionary, word count, reading time, tone, and **Find another word**. A dictation has a **Polish** button.
  Rewrites (clearer, shorter, rephrase, friendlier, more professional, more confident) use Apple Intelligence on the phone
  (iOS 26 and a supported iPhone; everything else about Polish works without it, and the tab says why rewrites are off).
  Settings › Writing: spelling (British, American, Canadian, Australian, Indian) and "Fix clear slips as I talk".
- A history (the newest 200), copy, share, and writing down an audio file.
- The dictionary is `dictionary.txt` in the app's Documents folder, so it shows in the Files app under
  On My iPhone › FreeFlow, and Settings › Dictionary can take the one from the Mac.

## App Store

`APP-STORE.md` lists what is needed to put it on the App Store (paid Apple Developer Program, listing, privacy answers) and
which parts need a decision from you.

## Not built yet

- A system-wide keyboard to dictate into any app. iOS does not let a keyboard use the microphone, so it hands off to the app to
  record. It also needs explicit app IDs with an App Group, which means registering them in the Apple developer account.
- The tidy-up AI (Ollama on the Mac), meeting notes, Command Mode and the Workday notes.
- Polish suggestions inside other apps as you type (only a system keyboard could do that).
- Learning from corrections.

## Build and test

The grammar checker is a Rust library (Harper, Apache-2.0). Build it once for the phone and the simulator (needs Rust):

```
scripts/build-harper.sh ios iossim   # writes native/harper/libharper-ios.a and libharper-iossim.a (a few minutes)
```

then:

```
brew install xcodegen          # once
cd ios && xcodegen generate    # makes FreeFlowPhone.xcodeproj from project.yml (not committed)
xcodebuild test -project FreeFlowPhone.xcodeproj -scheme FreeFlowPhone -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

A whole-route check without the microphone (downloads the model the first time):

```
xcrun simctl launch --console-pty booted com.momominibot.freeflow.phone --transcribe /path/to/audio.wav --model base --language en
```

It prints `FFTEST:` lines with the raw words and the finished text.

Running on a real iPhone needs the phone plugged in and unlocked, and a development profile that includes its UDID
(the wildcard one saved at `~/.local/share/mobile-mcp/michiyomimi-dev.mobileprovision` covers the team's apps).
