# Putting FreeFlow for iPhone on the App Store

Written 10 Nov 2026. Nothing here has been submitted, bought or published: each step marked **needs your yes** costs money,
creates an account or makes the app public.

## What is ready in the project

- The app builds, the 20 unit checks pass on the simulator, and Polish (spelling, grammar, rewrites, word swaps) works with
  no connection and no account.
- Privacy answers are simple and true: the voice and the writing never leave the phone. `App/PrivacyInfo.xcprivacy` declares no
  tracking, no collected data, and the one required-reason API the app uses (UserDefaults, reason CA92.1).
  `ITSAppUsesNonExemptEncryption` is `false` (only iOS's own https, used to download the speech model once).
- Open-source notices ship inside the app: Settings › About and licences (`App/Resources/ThirdPartyNotices.txt`, made by
  `python3 scripts/gen-notices.py`). Harper (Apache-2.0) and WhisperKit (MIT) both require the notice to travel with the app.
  Three small Rust libraries inside Harper are MPL-2.0 (colored, cssparser, dtoa-short): unmodified, source public, named in the notices.
- Microphone text is in `Info.plist`; there is no sign-in, no ads and no analytics, so there is no tracking prompt.

## What it needs, in order

1. **Apple Developer Program membership (needs your yes, paid yearly).** Without it an app can only run on your own devices.
   Enrol at developer.apple.com/programs with the Apple ID you want as the seller; an individual enrolment is quickest, a company
   needs a D-U-N-S number. The project already names team `X534KT8F6Z` for development builds.
2. **A unique app name.** "FreeFlow" is probably taken in the store. Check in App Store Connect when you create the app record,
   and keep a subtitle ready (up to 30 characters, for example "Voice to text, polished").
3. **App Store Connect record (needs your yes).** New app, iOS, bundle ID `com.momominibot.freeflow.phone` (register it under
   Certificates, Identifiers and Profiles first), SKU of your choice, primary language English.
4. **Pages that must exist on the web:** a privacy policy URL and a support URL (a plain page is enough). The policy can say
   exactly what the app does: no data collected, voice processed on the device, the speech model downloaded once from Hugging Face.
5. **Store listing:** description, keywords, category (Productivity), age rating questionnaire (answers are all "none"), and
   screenshots for the 6.9 inch iPhone (App Store Connect scales them for smaller sizes). Pictures can be taken from the simulator.
6. **App Privacy answers:** "Data Not Collected". Export compliance: the app uses only standard encryption provided by iOS.
7. **Build and upload.** In Xcode choose Product › Archive on a generic iOS device, then Distribute App › App Store Connect.
   TestFlight (free, part of membership) lets you and friends install it first. **Public release needs your yes.**
8. **Review.** Typically about a day. Likely questions and answers:
   - *Why does it download a model on first launch?* A speech recognition model (the largest one is 626 MB) is fetched once so recognition
     runs on the phone. It is data, not code (guideline 2.5.2 is about executable code). Say so in the review notes, and say the
     first launch needs a connection.
   - *Minimum functionality (4.2).* Talk plus Polish is a real tool, not a web page in a wrapper. Give the reviewer the steps:
     allow the microphone, hold the button and speak, then open Polish and tap "Try an example".
   - *Apple Intelligence.* Rewrites run only where Apple's on-device model is available; elsewhere the app says why and everything else works.
     Reviewers on older devices see that message, which is expected.

## Money: the decision for you

It costs nothing to run (no server), so any price is margin. Apple keeps 30 percent (15 percent through the App Store Small Business
Program, which you apply for in App Store Connect). Options, with my recommendation first:

1. **Free to download, one-time purchase to unlock Polish rewrites and unlimited history.** Fits an app with no running costs,
   and people tend to dislike subscriptions for tools that run offline. Needs a StoreKit in-app purchase (about a day of work).
2. **Paid upfront.** Simplest, no StoreKit, but no free trial, which hurts a voice app people want to try first.
3. **Subscription.** Highest income if the app has constant new value, but Grammarly-style subscription fatigue is real and
   there is nothing server-side to justify a monthly fee.

I have not researched competitor prices; check the top voice-to-text and writing apps in the store before fixing a number.

## Not built, and why it matters for the store

- A system keyboard (dictate into any app) is what most people expect from a dictation app, and it is the biggest reason
  someone would pay. It needs new App IDs and an App Group, which means your Apple account (step 1 first).
- Polish suggestions inside other apps as you type depend on that keyboard.
