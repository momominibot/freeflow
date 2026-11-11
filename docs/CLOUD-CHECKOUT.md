# Purrscribe Cloud checkout: making the Stripe link, and what is still open (checked 2026-11-11)

> `cloud/stripe/create_checkout.py` creates the Stripe product, monthly price and Payment Link for the paid Cloud plan, on Ranklore Pte Ltd's Stripe account. The Mac app only opens the link the script prints. **Nothing has been created in Stripe yet, not in test mode and not live, and there is no backend behind the plan.**

## 1. What exists and what does not

Exists in this repo:

- `cloud/stripe/create_checkout.py`: the setup script. Python standard library only. It runs on the Mac's own `python3` (3.9) and on newer versions.
- `cloud/stripe/test_create_checkout.py`: tests that run the script against a fake Stripe server on this Mac (see "Tests" in section 3).
- The app side: `build.sh` and `Sources/Plans.swift` take the link and use it (section 7).
- This page.

Does not exist:

- **Nothing is created in Stripe.** No product, price or Payment Link, in test mode or in live mode. The script has only ever run against the fake server. It has never talked to the real Stripe API.
- **The price is a placeholder.** 12.00 SGD a month is only a default so the script has a number to send in test mode. Nobody has chosen the real price, and the script refuses to create anything in the live account until `--amount` is given.
- **No backend and no licence delivery.** Nothing notices a payment, and nothing gives the buyer an account, a licence or cloud features. Today a buyer would get a Stripe receipt and nothing else. Do not put the link in a build that other people use until that exists.
- **No tax setup.** The script turns on no automatic tax and sets no tax behaviour on the price. If Ranklore has to charge GST, the owner decides how that shows before going live.
- **The customer portal is not turned on** (section 5), and **the webhook guard is not applied** (section 6).

## 2. What the script does

1. **Finds the key.** From the environment variable `STRIPE_SECRET_KEY`, otherwise from the first line of `~/.config/stripe/ranklore_api_key`. It prints only the kind of key (`sk_test`, `rk_test`, `sk_live` or `rk_live`), never the key. Its output contains no secrets.
2. **Checks whose account it is.** It asks Stripe which account the key belongs to and prints the account id, display name, country and default currency. If none of the account's names (dashboard display name, business name, company name) contains `ranklore`, in any case, it stops with exit code 3 and creates nothing. `--expect-name` changes the text it looks for.
3. **Looks at what already exists.** A price with the lookup key `purrscribe_cloud_monthly`, and active Payment Links tagged `app=purrscribe` and `plan=cloud_monthly`. A link only counts if its one line item is that price.
4. **Creates only what is missing**, in this order: the product `purrscribe_cloud` (named "Purrscribe Cloud"), the monthly price, the Payment Link.
5. **Prints the link.** On success the last line is the URL, with nothing after it.

Running it again creates nothing and prints the same URL. If a run stops half way, for example the product was made and the price failed, run it again: it finds what is there and carries on. It never deletes, deactivates or edits anything that already exists. It only touches Stripe's account, product, price and Payment Link endpoints. It never creates a customer, a charge or a webhook.

The Payment Link is set up like this:

- One item: the monthly price, quantity 1, as a subscription.
- Promotion codes are allowed.
- The billing address is collected only when Stripe needs it.
- After paying, the buyer sees Stripe's own confirmation page with this message: "Thank you for subscribing to Purrscribe Cloud." It promises nothing about receipts or cancelling, because those depend on Dashboard settings nobody has checked (section 5).
- The tags `app=purrscribe` and `plan=cloud_monthly` sit on the link and are also put on every subscription it starts. The webhook guard in section 6 relies on them.

## 3. How to run it

Run everything from the repo root.

### Test mode first

Test mode (Stripe also calls it a sandbox) creates nothing real and moves no money.

1. In the Stripe Dashboard, in test mode, make an API key. A restricted key (it starts with `rk_test`) is the better choice: give it write access to Products, Prices and Payment Links and nothing else. See "Keys" below.
2. Save it where the script looks. Use an editor, not the command line, so the key does not end up in your shell history:

   ```
   mkdir -p ~/.config/stripe
   nano ~/.config/stripe/ranklore_api_key
   chmod 600 ~/.config/stripe/ranklore_api_key
   ```

   Paste the key on the first line and save. You can also set `STRIPE_SECRET_KEY` for one terminal session. If both exist, the variable wins, so a stray one in your environment beats the file. Read the `key kind` line at the top of the output every time.
3. Look first, create nothing:

   ```
   python3 cloud/stripe/create_checkout.py --dry-run
   ```

   It only reads from Stripe, prints the account it found, and lists the requests it would send. Check that the account is Ranklore's.
4. Create the test objects:

   ```
   python3 cloud/stripe/create_checkout.py
   ```
5. Open the printed link and pay with one of Stripe's published test cards (Stripe's testing page lists them). Then run the checks in section 4 on that test subscriber, and look at sections 5 and 6.

### Then live

1. Make a live key the same way (`rk_live`, same permissions).
2. Run the script with it and the real price, without `--yes-live`. A live key creates nothing by itself: the script prints what it would create in the live account and exits with 2. It still reads from the live account, because it has to in order to say what is missing.
3. Only when the owner says yes, run it again with `--yes-live` and the same price:

   ```
   python3 cloud/stripe/create_checkout.py --amount 15.00 --yes-live
   ```

   15.00 is only an example: use the price the owner decided. `--yes-live` without `--amount` is refused (exit 64) before anything is sent, because 12.00 is only a placeholder.
4. Put the printed link into the build (section 7). The top of the output says `key kind: ... (test mode)` or `(LIVE mode)`. Check that line before copying a link anywhere. A test-mode link must never go into a build other people use.

Settle these before the first live run: the real price, the webhook guard (section 6), the customer portal and receipt emails (section 5), and whatever delivers the cloud service to the buyer (section 1).

### Options

| Option | What it does |
|---|---|
| `--amount 15` | Price per month in whole currency units. Left out, a test key uses 12.00, a placeholder. Anything created in the live account needs it given. |
| `--currency SGD` | Three-letter currency code. Default SGD. |
| `--expect-name text` | The account must have a name containing this text, in any case. Default `ranklore`. |
| `--dry-run` | Reads from Stripe and prints the requests it would send. Sends no POST, in any mode, even with `--yes-live`. |
| `--yes-live` | Lets a live key create things, together with `--amount`. Without it a live key creates nothing. |
| `--new-price` | See "Changing the price" below. |

The amount is turned into Stripe's smallest unit with exact decimal arithmetic, never floating point. Currencies Stripe counts in whole units (JPY, for example) are handled. Currencies with three decimal places (KWD, for example) are refused with a message, because Stripe has special rules for them. Check Stripe's currencies page before using anything other than SGD.

The environment variable `STRIPE_API_BASE` exists only so the tests can point the script at a fake server on this Mac. The script accepts only `https://api.stripe.com`, `127.0.0.1` and `localhost` there, and refuses a live key on anything but the real API.

### Changing the price

If a price with the lookup key already exists but differs from what you asked for (amount, currency or interval), the script stops with exit code 6, says what it found, and changes nothing. To really change it, run again with `--new-price`. That creates a new price, which takes the lookup key over from the old one (Stripe's `transfer_lookup_key`), and a new Payment Link for it. The old price and the old link stay active, and subscribers already on the old price stay on it. Retiring the old link is a Dashboard step: the script deactivates nothing. If the existing price already matches, `--new-price` does nothing extra. Asking without `--amount` compares against the 12.00 placeholder, so pass the same `--amount` on every run against a live account.

If Stripe refuses to create the price because the lookup key is already in use (for example by an archived price), run again with `--new-price` as well. The exact refusal text has not been seen.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Done. The last line of output is the link. This also covers "everything already existed". |
| 2 | Live gate. A live key was used without `--yes-live` and something would have been created. Nothing was sent. |
| 3 | None of the account's names contains the expected text. Nothing was created. |
| 4 | Stripe or the network said no. The script prints only Stripe's own error message and the request id from the response (give that id to Stripe support). |
| 5 | No usable key was found. |
| 6 | Stripe already holds something a person has to decide about: a price with different terms, a stale Purrscribe link with no matching price, an archived product, or more links than the script will scan. The message says which. |
| 64 | A bad option value, such as an amount that is not a number, or `--yes-live` without `--amount`. It is not 2 on purpose, because 2 means the live gate. |
| 1 | An unexpected error. |

### Keys

The script accepts `sk_test`, `rk_test`, `sk_live` and `rk_live` keys and refuses anything else, including publishable keys. It reads and writes products, prices and Payment Links, and it reads the account. A restricted key therefore needs write access to Products, Prices and Payment Links. Which permission Stripe wants for the account read is not confirmed: if the script stops at the identity step with a permission message, add what the message names. For a test-mode run you can also use a full test secret key.

### Tests

```
/opt/homebrew/bin/python3.14 -I -m unittest discover -s cloud/stripe -v
```

The tests start a fake Stripe server on 127.0.0.1 and check the script against it: the identity refusal, the live gate and the dry run (zero POSTs each), a live creation without `--amount` (refused before anything is sent), a second run (zero POSTs), a price mismatch, `--new-price`, the exact form fields sent, the amount table, the key never showing up in output, Stripe errors, and a missing key. The fake server rejects unknown, missing or repeated fields, and a guard makes any test that tries to reach another host fail. The keys used in the tests are made up. The system `python3` (3.9) passes them too.

## 4. The three checks on the first real subscriber

An active subscription, or an invoice that says "paid", does not prove that a card is on file. Before anyone says the first subscriber has paid, check all three:

1. **The subscription's `default_payment_method` is not null.**
2. **The latest invoice's payment succeeded.** Its payment intent has the status `succeeded`. On newer Stripe API versions the invoice has no `payment_intent` field; it lists its payments instead, and the payment there should be `paid`.
3. **The customer has a payment method attached.**

A zero-amount invoice that Stripe marks as paid proves nothing. Stripe marks such an invoice paid even when no card was ever entered. Here that can happen with a 100 percent promotion code (the link allows promotion codes) or with a trial added later. For a zero-amount first invoice, only checks 1 and 3 tell you whether a card is on file. If none is, the first real charge will fail and the subscription goes past due.

Do the same checks on the test subscriber from section 3. You can read all of this in the Dashboard (customer, subscription, invoice) or through the API with a read-only key.

## 5. Customer portal and receipts (owner steps, not done)

**The Stripe customer portal is not turned on.** It lets a subscriber update a card or cancel without writing to anyone. Turning it on is a Dashboard step that only the owner can do. Nobody has done it, and nothing in this repo can. In the Dashboard it is under Settings, Billing, Customer portal, with a button to activate it (Stripe's docs call it "Activate link"). Test mode and live mode have separate portal settings, so do it in both. Until it is on, a subscriber has no way to cancel or change a card without writing to Ranklore, and someone would have to read that and act on it.

**Receipts.** The thank-you message promises no receipt, because that depends on the settings below. From Stripe's receipts page, not tested:

- Stripe sends receipts automatically only when the "Successful payments" customer email is switched on in the Dashboard's customer email settings. Test payments never send automatic receipts.
- A receipt shows the business's support email, so set one in the public business details.
- Where a reply to a receipt email lands is not confirmed. Make sure it reaches a mailbox that someone reads.

## 6. An existing webhook on the same Stripe account would email every Purrscribe buyer

**Status: the guard below has NOT been applied.** No webhook has been touched. Applying it needs the owner's yes, an edit to that webhook's code, and a deploy.

The Stripe account that sells Purrscribe Cloud may already have a production webhook for another product, for example one that sends a welcome email on every `checkout.session.completed` event. Such a webhook does not look at what was bought. Stripe sends that event for every Payment Link on the account, so a Purrscribe Cloud buyer would get an email about a product they never bought. Open the account's webhook endpoints in the Dashboard and read what each one does before the first checkout.

The fix is a guard at the top of the `checkout.session.completed` branch of that webhook, straight after the session object is read (here `const session = event.data.object;`):

```js
// Purrscribe Cloud checkouts are not Ranklore dashboard sign-ups. Skip them.
if (session.metadata?.app === "purrscribe") {
  return res.status(200).json({ received: true, skipped: "purrscribe" });
}
// Fallback in case the metadata is ever missing. Test mode and live mode links have different ids.
const PURRSCRIBE_LINK_IDS = new Set(["plink_TEST_ID_GOES_HERE", "plink_LIVE_ID_GOES_HERE"]);
if (session.payment_link && PURRSCRIBE_LINK_IDS.has(session.payment_link)) {
  return res.status(200).json({ received: true, skipped: "purrscribe" });
}
```

How it works:

- A Payment Link's metadata is copied onto each Checkout Session the link creates, according to Stripe's Payment Links API reference. That is why `session.metadata.app` can be checked. This comes from the docs only: no real session has been seen. On the first test checkout, open the `checkout.session.completed` event in the Dashboard and confirm that `metadata.app` is `purrscribe`.
- The second guard uses `session.payment_link`, which holds the id of the link that made the session. The script prints that id as "payment link id". Test mode and live mode links have different ids, so list both.
- Both guards return 200, so Stripe does not retry the event.

Until the guard is deployed, or you have checked that no such webhook exists, do not run a live Purrscribe checkout, not even a purchase of your own. Also find out whether such a webhook is registered for test mode events before the first test checkout.

Later, when a Purrscribe backend exists, it should do the mirror image: act only on sessions whose `metadata.app` is `purrscribe` (or whose link id matches) and ignore everything else on the account.

## 7. How the app uses the link

The Mac app opens one URL and nothing else. `build.sh` reads the environment variable `PURRSCRIBE_CHECKOUT_URL` and writes it into the built app's `Info.plist` under the key `PurrscribeCloudCheckoutURL`. The checked-in `Info.plist` does not carry it, on purpose:

```
PURRSCRIBE_CHECKOUT_URL=https://buy.stripe.com/... ./build.sh release
```

- `build.sh` accepts only a link that starts with `https://`. Anything else stops the build.
- `Sources/Plans.swift` reads the key and ignores anything that is not a plain https link with a host.
- With no link, the cloud plan shows "Coming soon".
- Use a live link only in a build whose cloud service exists (section 1), and never put a test-mode link in a build other people use.

## 8. Not checked against real Stripe

The script was written from Stripe's public docs (read on 2026-11-11) and has only run against the fake server. The fake rejects unknown, missing and repeated fields, so the field names are checked twice, but only Stripe can confirm them. Not confirmed:

- The first real run, in either mode.
- The account lookup without an id. The reference page read documents fetching an account by id. The call the script makes (the account the key belongs to) was not on it.
- Which permissions a restricted key needs for that account lookup.
- The lists of whole-unit and three-decimal currencies. They could not be read in full from Stripe's currencies page. SGD, the default, is a two-decimal currency and is not affected.
- Whether a Payment Link's metadata really arrives on the Checkout Session (section 6). The docs say so.
- Receipt behaviour, and where replies to receipt emails go (section 5).
- Whether the customer portal has separate test and live links. This is inferred from the docs.
- The script sets no API version, so the account's default is used. That decides the field names in check 2 of section 4.

Stripe pages read: Payment Links (create, list, line items, object), Prices (create, list), Products (create), Accounts (retrieve), the Checkout Session, Subscription, Invoice and Invoice Payment objects, Expanding objects, Errors, Request IDs, Currencies, API keys and restricted keys, Authentication, Customer portal activation and Receipts.
