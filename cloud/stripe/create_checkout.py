#!/usr/bin/env python3
"""Create the Stripe checkout for the Purrscribe Cloud plan, safely and repeatably.

On the Stripe account the key belongs to, this script:
  1. checks that the account really is Ranklore's (it refuses otherwise),
  2. finds or creates the product (id purrscribe_cloud),
  3. finds or creates a monthly price (lookup key purrscribe_cloud_monthly),
  4. finds or creates a Payment Link for that price (a subscription),
and prints the Payment Link URL as the very last line of output.

Running it a second time creates nothing. A live key never creates anything
unless --yes-live and --amount are both given (the built-in price is only a
placeholder). The key is never printed, only its kind.

Standard library only. Python 3.9 or newer.
Full notes: docs/CLOUD-CHECKOUT.md
"""

import argparse
import http.client
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from decimal import Decimal

# What we create. Changing these changes what "already exists" means.
LOOKUP_KEY = "purrscribe_cloud_monthly"
APP = "purrscribe"
PLAN = "cloud_monthly"
PRODUCT_ID = "purrscribe_cloud"
PRODUCT_NAME = "Purrscribe Cloud"
# Says only what is certain. Receipts and the way to cancel depend on settings in
# the Stripe Dashboard that nobody has checked yet, so they are not promised here.
THANK_YOU_MESSAGE = "Thank you for subscribing to Purrscribe Cloud."

DEFAULT_AMOUNT = "12.00"  # a placeholder price, not a decision
DEFAULT_CURRENCY = "SGD"
DEFAULT_EXPECT_NAME = "ranklore"
KEY_FILE_RELATIVE = os.path.join(".config", "stripe", "ranklore_api_key")

STRIPE_HOST = "api.stripe.com"
DEFAULT_BASE = "https://" + STRIPE_HOST
LOCAL_HOSTS = ("127.0.0.1", "localhost")
USER_AGENT = "purrscribe-checkout-setup/1.0"
TIMEOUT_SECONDS = 30
MAX_LIST_PAGES = 20
MAX_LINE = 600

EXIT_OK = 0
EXIT_UNEXPECTED = 1
EXIT_LIVE_GATE = 2
EXIT_IDENTITY = 3
EXIT_API = 4
EXIT_NO_KEY = 5
EXIT_NEEDS_DECISION = 6
EXIT_USAGE = 64  # not 2, because 2 means the live gate

# Stripe wants amounts in the smallest currency unit. These lists come from
# Stripe's currencies page; see docs/CLOUD-CHECKOUT.md for what is unverified.
ZERO_DECIMAL = frozenset(
    ["bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf", "vnd", "vuv", "xaf", "xof", "xpf"]
)
# Stripe still wants these two as two-decimal amounts, in whole units only.
TWO_DECIMAL_WHOLE_UNITS = frozenset(["isk", "ugx"])
THREE_DECIMAL = frozenset(["bhd", "jod", "kwd", "omr", "tnd"])

_KEY_RE = re.compile(r"^(sk|rk)_(test|live)_[A-Za-z0-9_]+$")
_KEY_LIKE_RE = re.compile(r"(?:sk|rk|pk)_(?:test|live)_[A-Za-z0-9_*.\-]+")
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f]")
_AMOUNT_RE = re.compile(r"^[0-9]{1,12}(\.[0-9]{1,6})?$")
_CURRENCY_RE = re.compile(r"^[A-Za-z]{3}$")


class UsageError(Exception):
    """A bad command line value or environment setting."""


class KeyMissing(Exception):
    """No usable Stripe key. The message never contains the key."""


class IdentityMismatch(Exception):
    """The key belongs to a different Stripe account than expected."""


class NeedsDecision(Exception):
    """Stripe already holds something that a person has to decide about."""


class PostBlocked(Exception):
    """A POST was attempted when none is allowed. This is a bug if it ever happens."""


class ApiError(Exception):
    """Stripe (or the network) said no. Carries only safe fields."""

    def __init__(self, message, status=None, request_id=None, code=None, method=None, path=None):
        Exception.__init__(self, message)
        self.message = message
        self.status = status
        self.request_id = request_id
        self.code = code
        self.method = method
        self.path = path


# ---------------------------------------------------------------- output


class Out(object):
    """Everything printed goes through here, so the key cannot leak into output."""

    def __init__(self, stdout, stderr):
        self._stdout = stdout
        self._stderr = stderr
        self._secrets = []

    def hide(self, secret):
        if secret and secret not in self._secrets:
            self._secrets.append(secret)

    def clean(self, text):
        text = str(text)
        for secret in self._secrets:
            text = text.replace(secret, "[redacted]")
        text = _KEY_LIKE_RE.sub("[redacted]", text)
        text = _CONTROL_RE.sub(" ", text)
        if len(text) > MAX_LINE:
            text = text[:MAX_LINE] + "..."
        return text

    def say(self, text=""):
        self._write(self._stdout, self.clean(text) + "\n")

    def err(self, text=""):
        self._write(self._stderr, self.clean(text) + "\n")

    @staticmethod
    def _write(stream, text):
        try:
            stream.write(text)
        except UnicodeEncodeError:
            stream.write(text.encode("ascii", "backslashreplace").decode("ascii"))
        flush = getattr(stream, "flush", None)
        if flush:
            flush()


def _fail(out, text):
    lines = str(text).split("\n")
    out.err("error: " + lines[0])
    for line in lines[1:]:
        out.err(line)


# ---------------------------------------------------------------- amounts


def to_minor_units(amount, currency):
    """Turn a human amount such as "12.00" into Stripe's smallest unit, as an int.

    Uses Decimal, never float. Zero-decimal currencies take no factor,
    three-decimal currencies are refused, everything else is multiplied by 100.
    """
    text = str(amount).strip()
    code = str(currency).strip().lower()
    if not _CURRENCY_RE.match(code):
        raise UsageError("the currency must be a three-letter code such as SGD (got %r)" % str(currency)[:20])
    if code in THREE_DECIMAL:
        raise UsageError(
            "%s is a three-decimal currency. This script does not handle those, "
            "so no price was made." % code.upper()
        )
    if not _AMOUNT_RE.match(text):
        raise UsageError("the amount must be a plain number such as 12.00 (got %r)" % text[:40])
    value = Decimal(text)
    if value <= 0:
        raise UsageError("the amount must be greater than zero")
    if code in TWO_DECIMAL_WHOLE_UNITS:
        if value != value.to_integral_value():
            raise UsageError("%s amounts must be whole units (got %s)" % (code.upper(), text))
        factor = 100
    elif code in ZERO_DECIMAL:
        factor = 1
    else:
        factor = 100
    minor = value * factor
    if minor != minor.to_integral_value():
        raise UsageError("%s has too many decimal places for %s" % (text, code.upper()))
    return int(minor)


def format_minor(minor, currency):
    """Show a smallest-unit amount as people write it, for messages only."""
    code = str(currency).lower()
    if not isinstance(minor, int):
        return "?"
    if code in ZERO_DECIMAL:
        return str(minor)
    if code in TWO_DECIMAL_WHOLE_UNITS and minor % 100 == 0:
        return str(minor // 100)
    if code in THREE_DECIMAL:
        return "%d.%03d" % (minor // 1000, minor % 1000)
    return "%d.%02d" % (minor // 100, minor % 100)


# ---------------------------------------------------------------- key and base


def load_key(environ):
    """Return (key, kind). The key comes from STRIPE_SECRET_KEY, else the key file."""
    raw = (environ.get("STRIPE_SECRET_KEY") or "").strip()
    source = "the environment variable STRIPE_SECRET_KEY"
    if not raw:
        home = environ.get("HOME") or os.path.expanduser("~")
        path = os.path.join(home, KEY_FILE_RELATIVE)
        source = path
        try:
            with open(path, "r") as handle:
                raw = handle.readline().strip()
        except (OSError, UnicodeDecodeError):
            raw = ""
    if not raw:
        raise KeyMissing(
            "no Stripe key found. Set STRIPE_SECRET_KEY, or put the key on the first line of "
            "~/.config/stripe/ranklore_api_key"
        )
    match = _KEY_RE.match(raw)
    if not match:
        raise KeyMissing(
            "the key from %s is not a Stripe secret or restricted key. "
            "Expected an sk_test, rk_test, sk_live or rk_live key." % source
        )
    return raw, "%s_%s" % (match.group(1), match.group(2))


def check_base(base):
    """Return (normalised base url, host). Only the real API or a local mock is allowed."""
    try:
        parts = urllib.parse.urlsplit(str(base).strip())
        port = parts.port
    except ValueError:
        raise UsageError("STRIPE_API_BASE is not a valid URL")
    host = (parts.hostname or "").lower()
    if parts.scheme not in ("http", "https"):
        raise UsageError("STRIPE_API_BASE must start with https:// (or http:// for a local mock)")
    if parts.username or parts.password:
        raise UsageError("STRIPE_API_BASE must not contain a user name or password")
    if parts.path not in ("", "/") or parts.query or parts.fragment:
        raise UsageError("STRIPE_API_BASE must be just a scheme, a host and an optional port")
    if host == STRIPE_HOST:
        if parts.scheme != "https" or port not in (None, 443):
            raise UsageError("STRIPE_API_BASE points at the real Stripe API, which must be reached over https on the normal port")
    elif host not in LOCAL_HOSTS:
        raise UsageError(
            "STRIPE_API_BASE host %r is not allowed. Only %s, 127.0.0.1 and localhost are accepted."
            % (host[:60], STRIPE_HOST)
        )
    return "%s://%s" % (parts.scheme, parts.netloc), host


# ---------------------------------------------------------------- http


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect: the key must only ever go where we sent it."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _urllib_send(method, url, headers, body):
    """The real transport. Returns (status, headers, body bytes)."""
    handlers = [_NoRedirect()]
    if urllib.parse.urlsplit(url).hostname in LOCAL_HOSTS:
        handlers.insert(0, urllib.request.ProxyHandler({}))
    opener = urllib.request.build_opener(*handlers)
    request = urllib.request.Request(url, data=body, method=method)
    for name, value in headers.items():
        request.add_header(name, value)
    try:
        response = opener.open(request, timeout=TIMEOUT_SECONDS)
        try:
            return response.status, dict(response.headers.items()), response.read()
        finally:
            response.close()
    except urllib.error.HTTPError as exc:
        try:
            data = exc.read()
        finally:
            exc.close()
        return exc.code, dict(exc.headers.items()), data


def _header(headers, name):
    wanted = name.lower()
    for key, value in (headers or {}).items():
        if str(key).lower() == wanted:
            return value
    return None


def _network_message(exc, host):
    reason = getattr(exc, "reason", None)
    if not isinstance(reason, BaseException):
        reason = exc
    text = "could not reach %s (%s: %s)" % (host, type(reason).__name__, reason)
    if isinstance(reason, ssl.SSLCertVerificationError) or isinstance(exc, ssl.SSLCertVerificationError):
        text += (
            ". Python could not verify Stripe's certificate. This script never turns "
            "verification off, so fix the Python certificate setup instead."
        )
    return text


class Client(object):
    """A very small Stripe client. GET always works; POST only when allowed."""

    def __init__(self, base, key, send=None, allow_post=False):
        self.base = base.rstrip("/")
        self._key = key
        self._send = send or _urllib_send
        self.allow_post = allow_post

    def get(self, path, params=None):
        return self._request("GET", path, params)

    def post(self, path, params):
        if not self.allow_post:
            raise PostBlocked("a POST to %s was attempted while POSTs are not allowed" % path)
        return self._request("POST", path, params)

    def _request(self, method, path, params):
        url = self.base + path
        body = None
        headers = {
            "Authorization": "Bearer " + self._key,
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        }
        pairs = list(params or [])
        if method == "GET":
            if pairs:
                url += "?" + urllib.parse.urlencode(pairs)
        else:
            body = urllib.parse.urlencode(pairs).encode("ascii")
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        try:
            status, reply_headers, raw = self._send(method, url, headers, body)
        except (OSError, http.client.HTTPException) as exc:
            host = urllib.parse.urlsplit(self.base).hostname
            raise ApiError(_network_message(exc, host), method=method, path=path)
        request_id = _header(reply_headers, "request-id")
        try:
            payload = json.loads(raw.decode("utf-8")) if raw else {}
        except (ValueError, UnicodeDecodeError):
            payload = None
        if 200 <= status < 300:
            if not isinstance(payload, dict):
                raise ApiError(
                    "Stripe sent a reply that is not a JSON object",
                    status=status, request_id=request_id, method=method, path=path,
                )
            return payload
        message = None
        code = None
        if isinstance(payload, dict) and isinstance(payload.get("error"), dict):
            message = payload["error"].get("message")
            code = payload["error"].get("code")
        if not isinstance(message, str) or not message:
            if 300 <= status < 400:
                message = "unexpected redirect; this script never follows redirects"
            else:
                message = "no error message was sent"
        raise ApiError(
            message, status=status, request_id=request_id,
            code=code if isinstance(code, str) else None, method=method, path=path,
        )


# ---------------------------------------------------------------- what to send


def product_params():
    return [
        ("id", PRODUCT_ID),
        ("name", PRODUCT_NAME),
        ("metadata[app]", APP),
        ("metadata[plan]", PLAN),
    ]


def price_params(product_id, minor, currency, transfer_key):
    params = [
        ("product", product_id),
        ("currency", currency.lower()),
        ("unit_amount", str(minor)),
        ("recurring[interval]", "month"),
        ("lookup_key", LOOKUP_KEY),
        ("metadata[app]", APP),
        ("metadata[plan]", PLAN),
    ]
    if transfer_key:
        params.append(("transfer_lookup_key", "true"))
    return params


def link_params(price_id):
    return [
        ("line_items[0][price]", price_id),
        ("line_items[0][quantity]", "1"),
        ("allow_promotion_codes", "true"),
        ("billing_address_collection", "auto"),
        ("after_completion[type]", "hosted_confirmation"),
        ("after_completion[hosted_confirmation][custom_message]", THANK_YOU_MESSAGE),
        ("metadata[app]", APP),
        ("metadata[plan]", PLAN),
        ("subscription_data[metadata][app]", APP),
        ("subscription_data[metadata][plan]", PLAN),
    ]


class Step(object):
    """One POST the script may make."""

    def __init__(self, what, path, build, store):
        self.what = what
        self.path = path
        self.build = build
        self.store = store


class _Preview(dict):
    """Stands in for ids that do not exist yet when only printing a plan."""

    def __missing__(self, key):
        return "<id from the step above>"


# ---------------------------------------------------------------- looking things up


def _data_list(reply, what):
    items = reply.get("data")
    if not isinstance(items, list):
        raise ApiError("Stripe's reply to the %s lookup had no data list" % what)
    return [item for item in items if isinstance(item, dict)]


def check_identity(client, out, expect):
    account = client.get("/v1/account")
    names = []
    dashboard = (account.get("settings") or {}).get("dashboard") or {}
    profile = account.get("business_profile") or {}
    company = account.get("company") or {}
    for candidate in (dashboard.get("display_name"), profile.get("name"), company.get("name")):
        if isinstance(candidate, str) and candidate.strip() and candidate.strip() not in names:
            names.append(candidate.strip())
    out.say("account:           %s" % account.get("id", "?"))
    out.say("display name:      %s" % (names[0] if names else "(none)"))
    out.say("country:           %s" % account.get("country", "?"))
    out.say("default currency:  %s" % account.get("default_currency", "?"))
    if not any(expect.lower() in name.lower() for name in names):
        raise IdentityMismatch(
            "refusing to continue. No name on account %s contains %r (names found: %s).\n"
            "This is not the account the script expects. If it is the right one, run again with "
            "--expect-name set to part of its name. Nothing was created."
            % (account.get("id", "?"), expect, ", ".join(names) if names else "none")
        )
    out.say('identity:          ok (a name contains "%s")' % expect)


def find_price(client):
    reply = client.get(
        "/v1/prices",
        [("lookup_keys[]", LOOKUP_KEY), ("active", "true"), ("expand[]", "data.product")],
    )
    for item in _data_list(reply, "price"):
        if item.get("lookup_key") == LOOKUP_KEY and item.get("active") is not False and isinstance(item.get("id"), str):
            return item
    return None


def describe_price(price):
    code = str(price.get("currency") or "?")
    unit = price.get("unit_amount")
    amount = format_minor(unit, code) if isinstance(unit, int) else "(no fixed amount)"
    recurring = price.get("recurring") or {}
    interval = recurring.get("interval")
    count = recurring.get("interval_count", 1)
    if not interval:
        every = "one time"
    elif count == 1:
        every = "per %s" % interval
    else:
        every = "every %s %ss" % (count, interval)
    return "%s %s %s" % (code.upper(), amount, every)


def price_matches(price, minor, currency):
    recurring = price.get("recurring") or {}
    return (
        price.get("type") == "recurring"
        and price.get("unit_amount") == minor
        and str(price.get("currency") or "").lower() == currency.lower()
        and recurring.get("interval") == "month"
        and recurring.get("interval_count", 1) == 1
    )


def product_id_of(price):
    product = price.get("product")
    if isinstance(product, dict):
        product = product.get("id")
    if not isinstance(product, str) or not product:
        raise NeedsDecision("the existing price %s does not say which product it belongs to." % price.get("id"))
    return product


def find_product(client):
    try:
        return client.get("/v1/products/%s" % urllib.parse.quote(PRODUCT_ID, safe=""))
    except ApiError as exc:
        if exc.status == 404:
            return None
        raise


def find_links(client):
    """Active payment links tagged app=purrscribe and plan=cloud_monthly, newest first."""
    found = []
    after = None
    for _ in range(MAX_LIST_PAGES):
        params = [("active", "true"), ("limit", "100")]
        if after:
            params.append(("starting_after", after))
        reply = client.get("/v1/payment_links", params)
        items = _data_list(reply, "payment link")
        for item in items:
            meta = item.get("metadata") or {}
            if item.get("active") is not False and meta.get("app") == APP and meta.get("plan") == PLAN:
                found.append(item)
        if not reply.get("has_more") or not items:
            return found
        after = items[-1].get("id")
        if not isinstance(after, str) or not after:
            return found
    raise NeedsDecision(
        "there are more active payment links than this script will scan (%d pages of 100), "
        "so it cannot be sure none of them is the Purrscribe link. Nothing was changed." % MAX_LIST_PAGES
    )


def link_price_ids(client, link_id):
    reply = client.get("/v1/payment_links/%s/line_items" % urllib.parse.quote(link_id, safe=""), [("limit", "10")])
    ids = []
    for item in _data_list(reply, "payment link line item"):
        price = item.get("price")
        price_id = price.get("id") if isinstance(price, dict) else price
        if isinstance(price_id, str):
            ids.append(price_id)
    return ids


# ---------------------------------------------------------------- the plan


def build_plan(client, out, args, minor, currency):
    """Look at what Stripe already holds and decide which POSTs are needed.

    Only GETs happen here. Returns (steps, ctx). ctx holds the ids already known.
    """
    ctx = {}
    steps = []
    price = find_price(client)
    links = find_links(client)
    if price is None:
        out.say("price:             none with lookup key %s" % LOOKUP_KEY)
    else:
        out.say("price:             %s, %s" % (price["id"], describe_price(price)))
    out.say("payment links:     %d active with app=%s plan=%s" % (len(links), APP, PLAN))

    def price_step(product_id):
        return Step(
            "price", "/v1/prices",
            lambda c: price_params(product_id, minor, currency, args.new_price), "price_id",
        )

    link_step = Step("payment link", "/v1/payment_links", lambda c: link_params(c["price_id"]), "link_id")

    if price is None:
        if links and not args.new_price:
            raise NeedsDecision(
                "Stripe has %d active payment link(s) tagged app=%s (%s) but no active price with lookup key %s.\n"
                "This script will not guess which price is right. Deactivate the stale link(s) in the Stripe "
                "Dashboard or put the lookup key back on the right price, then run again.\n"
                "To create a fresh price and a new link anyway, run again with --new-price. Nothing was changed."
                % (len(links), APP, ", ".join(str(link.get("id")) for link in links), LOOKUP_KEY)
            )
        product = find_product(client)
        if product is None:
            steps.append(Step("product", "/v1/products", lambda c: product_params(), "product_id"))
            out.say("product:           %s does not exist yet" % PRODUCT_ID)
        elif product.get("active") is False or product.get("deleted"):
            raise NeedsDecision(
                "the Stripe account has a product with id %s that is archived or deleted.\n"
                "Restore it in the Stripe Dashboard and run again. Nothing was changed." % PRODUCT_ID
            )
        else:
            out.say("product:           %s already exists" % PRODUCT_ID)
        steps.append(price_step(PRODUCT_ID))
        steps.append(link_step)
        return steps, ctx

    if not price_matches(price, minor, currency):
        if not args.new_price:
            raise NeedsDecision(
                "Stripe already has a price with lookup key %s: %s, %s.\n"
                "You asked for %s %s per month. Nothing was changed.\n"
                "To create a new price at the new terms and a new payment link, run again with --new-price. "
                "The old price and its links stay active; nothing is deactivated."
                % (LOOKUP_KEY, price["id"], describe_price(price), currency.upper(), format_minor(minor, currency))
            )
        steps.append(price_step(product_id_of(price)))
        steps.append(link_step)
        return steps, ctx

    ctx["price_id"] = price["id"]
    for link in links:
        if link_price_ids(client, str(link.get("id"))) == [price["id"]]:
            url = link.get("url")
            if not isinstance(url, str) or not url.startswith("https://"):
                raise ApiError("the existing payment link %s has no https url" % link.get("id"))
            ctx["link_id"] = link["id"]
            ctx["url"] = url
            out.say("payment link:      %s already uses this price" % link["id"])
            return steps, ctx
    steps.append(link_step)
    return steps, ctx


def print_plan(out, steps, ctx, title):
    out.say(title)
    preview = _Preview(ctx)
    for step in steps:
        out.say("")
        out.say("POST %s  (create the %s)" % (step.path, step.what))
        for name, value in step.build(preview):
            out.say("  %s=%s" % (name, value))


def execute(client, out, steps, ctx):
    for step in steps:
        out.say("creating the %s ..." % step.what)
        created = client.post(step.path, step.build(ctx))
        object_id = created.get("id")
        if not isinstance(object_id, str) or not object_id:
            raise ApiError("Stripe's reply to POST %s had no id" % step.path, method="POST", path=step.path)
        ctx[step.store] = object_id
        if step.store == "link_id":
            url = created.get("url")
            if not isinstance(url, str) or not url.startswith("https://"):
                raise ApiError("Stripe's reply to POST %s had no https url" % step.path, method="POST", path=step.path)
            ctx["url"] = url
        out.say("  created %s %s" % (step.what, object_id))


def finish(out, ctx):
    out.say("payment link id:   %s" % ctx["link_id"])
    out.say(ctx["url"])  # the last line of output, on purpose


# ---------------------------------------------------------------- command line


class _Parser(argparse.ArgumentParser):
    def __init__(self, *args, **kwargs):
        self._out = kwargs.pop("out")
        argparse.ArgumentParser.__init__(self, *args, **kwargs)

    def error(self, message):
        self._out.err(self.format_usage().rstrip())
        self._out.err("%s: error: %s" % (self.prog, message))
        raise SystemExit(EXIT_USAGE)

    def print_help(self, file=None):
        for line in self.format_help().rstrip().split("\n"):
            self._out.say(line)


def _build_parser(out):
    parser = _Parser(
        prog="create_checkout.py",
        description=(
            "Create (or find) the Stripe product, monthly price and Payment Link for Purrscribe Cloud. "
            "Safe to run again: it never makes a second copy. Details: docs/CLOUD-CHECKOUT.md"
        ),
        epilog=(
            "The key comes from the environment variable STRIPE_SECRET_KEY, else from the first line of\n"
            "~/.config/stripe/ranklore_api_key. It is never printed.\n"
            "\n"
            "exit codes:\n"
            "  0   ok, the last line of output is the Payment Link URL\n"
            "  2   live gate: a live key was given without --yes-live, nothing was created\n"
            "  3   the Stripe account is not the expected one\n"
            "  4   Stripe or network error\n"
            "  5   no usable key\n"
            "  6   Stripe already holds something that needs a decision (see the message)\n"
            "  64  bad command line value, or a live creation without --amount\n"
            "  1   unexpected error"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        allow_abbrev=False,
        out=out,
    )
    parser.add_argument("--amount", default=None,
                        help="price per month, in whole currency units such as 12.00. Left out, a test key uses "
                             + DEFAULT_AMOUNT + " as a placeholder. Creating anything in the live account needs it")
    parser.add_argument("--currency", default=DEFAULT_CURRENCY,
                        help="three-letter currency code (default: %(default)s)")
    parser.add_argument("--expect-name", default=DEFAULT_EXPECT_NAME,
                        help="refuse unless a name on the Stripe account contains this text, in any case (default: %(default)s)")
    parser.add_argument("--dry-run", action="store_true",
                        help="look things up and print the requests that would be made, but send no POST")
    parser.add_argument("--yes-live", action="store_true",
                        help="allow creating objects with a live key. Without it a live key creates nothing and exits 2")
    parser.add_argument("--new-price", action="store_true",
                        help="if the existing price differs, create a new price and a new link instead of stopping. "
                             "Nothing is deactivated")
    return parser


def run(argv, environ, out, send):
    args = _build_parser(out).parse_args(argv)
    currency = args.currency.strip().lower()
    amount_given = args.amount is not None
    minor = to_minor_units(args.amount if amount_given else DEFAULT_AMOUNT, args.currency)
    expect = args.expect_name.strip()
    if not expect:
        raise UsageError("--expect-name must not be empty, because that would accept any account")
    base, host = check_base(environ.get("STRIPE_API_BASE") or DEFAULT_BASE)
    key, kind = load_key(environ)
    out.hide(key)
    live = kind.endswith("_live")
    if live and host != STRIPE_HOST:
        raise UsageError("a live key may only be used with the real Stripe API (%s), not with %s" % (STRIPE_HOST, host))

    allow_post = (not args.dry_run) and (args.yes_live or not live)
    if live and allow_post and not amount_given:
        raise UsageError(
            "creating anything in the live account needs --amount, because the built-in %s is only a placeholder. "
            "Nothing was sent." % DEFAULT_AMOUNT
        )
    client = Client(base, key, send=send, allow_post=allow_post)

    out.say("Purrscribe Cloud checkout setup")
    out.say("key kind:          %s (%s mode)" % (kind, "LIVE" if live else "test"))
    out.say("api:               %s" % base)
    placeholder = "" if amount_given else " (placeholder, --amount was not given)"
    out.say("price requested:   %s %s per month%s" % (currency.upper(), format_minor(minor, currency), placeholder))
    if args.dry_run:
        out.say("mode:              dry run, no POST will be sent")
    elif live and not args.yes_live:
        out.say("mode:              live key without --yes-live, no POST will be sent")
    out.say("")

    check_identity(client, out, expect)
    out.say("")
    steps, ctx = build_plan(client, out, args, minor, currency)

    if not steps:
        out.say("Everything already exists. Nothing was created.")
        finish(out, ctx)
        return EXIT_OK
    if args.dry_run:
        out.say("")
        print_plan(out, steps, ctx, "Dry run. These requests would be made. None is sent:")
        out.say("")
        out.say("Dry run: no POST was sent and nothing was created.")
        return EXIT_OK
    if live and not args.yes_live:
        out.say("")
        print_plan(out, steps, ctx, "Live key. These requests would be made against the LIVE account:")
        out.say("")
        hint = ""
        if not amount_given:
            hint = " Also pass --amount with the real monthly price: the built-in %s is only a placeholder." % DEFAULT_AMOUNT
        out.err("Live gate: nothing was sent. Run again with --yes-live to create these in the live account." + hint)
        return EXIT_LIVE_GATE

    out.say("")
    execute(client, out, steps, ctx)
    finish(out, ctx)
    return EXIT_OK


def main(argv=None, environ=None, stdout=None, stderr=None, send=None):
    """Run the tool and return its exit code. Everything can be injected for tests."""
    out = Out(stdout if stdout is not None else sys.stdout, stderr if stderr is not None else sys.stderr)
    environ = os.environ if environ is None else environ
    argv = sys.argv[1:] if argv is None else list(argv)
    try:
        return run(argv, environ, out, send)
    except SystemExit as exc:
        if exc.code is None:
            return EXIT_OK
        return exc.code if isinstance(exc.code, int) else EXIT_UNEXPECTED
    except UsageError as exc:
        _fail(out, exc)
        return EXIT_USAGE
    except KeyMissing as exc:
        _fail(out, exc)
        return EXIT_NO_KEY
    except IdentityMismatch as exc:
        _fail(out, exc)
        return EXIT_IDENTITY
    except NeedsDecision as exc:
        _fail(out, exc)
        return EXIT_NEEDS_DECISION
    except ApiError as exc:
        where = " on %s %s" % (exc.method, exc.path) if exc.method and exc.path else ""
        status = " (HTTP %d)" % exc.status if exc.status else ""
        out.err("error: Stripe API call failed%s%s: %s" % (where, status, exc.message))
        if exc.request_id:
            out.err("Stripe request id: %s" % exc.request_id)
        return EXIT_API
    except KeyboardInterrupt:
        out.err("interrupted. Running the script again is safe: it finds what already exists.")
        return 130
    except Exception as exc:  # last resort; never show a traceback, it could hold the key
        out.err("error: unexpected %s: %s" % (type(exc).__name__, exc))
        out.err("Running the script again is safe: it finds what already exists.")
        return EXIT_UNEXPECTED


if __name__ == "__main__":
    sys.exit(main())
