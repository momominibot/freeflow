"""Tests for create_checkout.py, run against a strict fake Stripe on 127.0.0.1.

Real Stripe is never contacted: the fake server runs in this process, every key
used here is made up, and DNS lookups for any other host are blocked while the
tests run.

Run from the repository root:
    /opt/homebrew/bin/python3.14 -I -m unittest discover -s cloud/stripe -v
"""

import io
import json
import os
import re
import shutil
import socket
import sys
import tempfile
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock as umock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import create_checkout as cc  # noqa: E402

TEST_KEY = "sk_test_FAKEKEY0001"
RESTRICTED_TEST_KEY = "rk_test_FAKEKEY0002"
LIVE_KEY = "sk_live_FAKEKEY0003"
RESTRICTED_LIVE_KEY = "rk_live_FAKEKEY0004"
ALL_FAKE_KEYS = (TEST_KEY, RESTRICTED_TEST_KEY, LIVE_KEY, RESTRICTED_LIVE_KEY)
EM_DASH = chr(0x2014)

_real_getaddrinfo = socket.getaddrinfo
_guard = None


def _local_only_getaddrinfo(host, *args, **kwargs):
    if host not in ("127.0.0.1", "localhost"):
        raise AssertionError("tests may only talk to 127.0.0.1, not %r" % (host,))
    return _real_getaddrinfo(host, *args, **kwargs)


def setUpModule():
    global _guard
    _guard = umock.patch("socket.getaddrinfo", _local_only_getaddrinfo)
    _guard.start()


def tearDownModule():
    _guard.stop()


def forbidden_send(*args, **kwargs):
    raise AssertionError("no request may be sent in this test")


def closed_port():
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


# ------------------------------------------------------------ the fake Stripe


class Override(object):
    """Make the fake answer a chosen way for matching requests."""

    def __init__(self, method, prefix, status, body, headers=None, times=None):
        self.method = method
        self.prefix = prefix
        self.status = status
        self.body = body
        self.headers = headers or {}
        self.times = times

    def matches(self, method, path):
        return (
            self.method == method
            and path.startswith(self.prefix)
            and (self.times is None or self.times > 0)
        )


def account_object(name, country="SG", currency="sgd", where="dashboard"):
    account = {"id": "acct_MOCK0001", "object": "account", "country": country, "default_currency": currency}
    if where == "dashboard":
        account["settings"] = {"dashboard": {"display_name": name}}
    elif where == "profile":
        account["business_profile"] = {"name": name}
    elif where == "company":
        account["company"] = {"name": name}
    return account


PRODUCT_PATTERNS = [r"^(id|name|active|description)$", r"^metadata\[[^\]]+\]$"]
PRICE_PATTERNS = [
    r"^(product|currency|unit_amount|lookup_key|transfer_lookup_key|nickname|active|billing_scheme|tax_behavior)$",
    r"^recurring\[(interval|interval_count|usage_type)\]$",
    r"^metadata\[[^\]]+\]$",
]
LINK_PATTERNS = [
    r"^(allow_promotion_codes|billing_address_collection|customer_creation|submit_type)$",
    r"^line_items\[\d+\]\[(price|quantity)\]$",
    r"^after_completion\[type\]$",
    r"^after_completion\[hosted_confirmation\]\[custom_message\]$",
    r"^after_completion\[redirect\]\[url\]$",
    r"^metadata\[[^\]]+\]$",
    r"^subscription_data\[metadata\]\[[^\]]+\]$",
    r"^subscription_data\[(description|trial_period_days)\]$",
]
PRICE_LIST_PATTERNS = [r"^(lookup_keys\[\]|active|expand\[\]|limit|starting_after|product|currency|type)$"]
LINK_LIST_PATTERNS = [r"^(active|limit|starting_after|ending_before|expand\[\])$"]
LINE_ITEM_LIST_PATTERNS = [r"^(limit|starting_after|ending_before|expand\[\])$"]


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _serve(self, method):
        parts = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qsl(parts.query, keep_blank_values=True)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        body = urllib.parse.parse_qsl(raw.decode("utf-8"), keep_blank_values=True)
        headers = dict((k.lower(), v) for k, v in self.headers.items())
        status, reply_headers, payload = self.server.mock.handle(method, parts.path, query, body, headers, raw)
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode("utf-8")
        self.send_response(status)
        for name, value in reply_headers.items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._serve("GET")

    def do_POST(self):
        self._serve("POST")


class MockStripe(object):
    """A small, strict imitation of the Stripe calls the script makes.

    Strict on purpose: unknown parameters, repeated parameters, missing required
    parameters and wrong values are rejected the way Stripe rejects them, so a
    wrong parameter name in the script shows up as a failing test.
    """

    def __init__(self, account=None):
        self.keys = set(ALL_FAKE_KEYS)
        self.account = account if account is not None else account_object("Ranklore Pte Ltd")
        self.requests = []
        self.products = {}
        self.prices = []
        self.links = []
        self.overrides = []
        self._requests_seen = 0
        self._objects = 0
        self._lock = threading.RLock()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self.server.mock = self
        self._thread = None

    # -- lifecycle
    @property
    def base(self):
        return "http://127.0.0.1:%d" % self.server.server_address[1]

    def start(self):
        self._thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.02})
        self._thread.daemon = True
        self._thread.start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self._thread.join(5)

    # -- what the tests look at
    def posts(self):
        return [r for r in self.requests if r["method"] == "POST"]

    def paths(self, method=None):
        return [r["path"] for r in self.requests if method is None or r["method"] == method]

    def forget_requests(self):
        with self._lock:
            self.requests = []

    @staticmethod
    def form(record):
        pairs = record["body"]
        result = dict(pairs)
        assert len(result) == len(pairs), "a form field was sent twice"
        return result

    # -- seeding objects directly
    def _new_id(self, prefix):
        self._objects += 1
        return "%s_mock_%03d" % (prefix, self._objects)

    def add_product(self, product_id=cc.PRODUCT_ID, active=True, name=cc.PRODUCT_NAME, live=False):
        product = {"id": product_id, "object": "product", "active": active, "name": name,
                   "metadata": {"app": cc.APP, "plan": cc.PLAN}, "livemode": live}
        self.products[product_id] = product
        return product

    def add_price(self, amount=1200, currency="sgd", interval="month", interval_count=1,
                  lookup_key=cc.LOOKUP_KEY, active=True, product=cc.PRODUCT_ID, live=False):
        price = {
            "id": self._new_id("price"), "object": "price", "active": active, "currency": currency,
            "unit_amount": amount, "lookup_key": lookup_key, "product": product, "type": "recurring",
            "recurring": {"interval": interval, "interval_count": interval_count, "usage_type": "licensed"},
            "metadata": {"app": cc.APP, "plan": cc.PLAN}, "livemode": live,
        }
        self.prices.append(price)
        return price

    def add_link(self, metadata=None, active=True, price_id=None, live=False):
        link_id = self._new_id("plink")
        number = link_id.split("_")[-1]
        link = {
            "id": link_id, "object": "payment_link", "active": active, "livemode": live,
            "metadata": dict(metadata if metadata is not None else {"app": cc.APP, "plan": cc.PLAN}),
            "url": "https://buy.stripe.com/%smock_%s" % ("" if live else "test_", number),
        }
        self.links.append({"link": link, "price_id": price_id})
        return link

    def link(self, link_id):
        for entry in self.links:
            if entry["link"]["id"] == link_id:
                return entry["link"]
        return None

    # -- the HTTP side
    def handle(self, method, path, query, body, headers, raw):
        with self._lock:
            self._requests_seen += 1
            request_id = "req_mock_%03d" % self._requests_seen
            self.requests.append({"method": method, "path": path, "query": query, "body": body,
                                  "headers": headers, "raw": raw, "request_id": request_id})
            reply = {"Request-Id": request_id, "Content-Type": "application/json"}
            for override in self.overrides:
                if override.matches(method, path):
                    if override.times is not None:
                        override.times -= 1
                    merged = dict(reply)
                    merged.update(override.headers)
                    return override.status, merged, override.body
            auth = headers.get("authorization", "")
            token = auth[len("Bearer "):] if auth.startswith("Bearer ") else None
            if token is None or token not in self.keys:
                return self._error(401, reply, "Invalid API Key provided: %s" % (token or "(none)"))
            live = token.startswith(("sk_live_", "rk_live_"))
            if method == "GET" and path == "/v1/account":
                return 200, reply, self.account
            if method == "GET" and path == "/v1/prices":
                return self._list_prices(query, reply)
            if method == "GET" and path == "/v1/payment_links":
                return self._list_links(query, reply)
            match = re.match(r"^/v1/products/([^/]+)$", path)
            if method == "GET" and match:
                return self._get_product(urllib.parse.unquote(match.group(1)), reply)
            match = re.match(r"^/v1/payment_links/([^/]+)/line_items$", path)
            if method == "GET" and match:
                return self._line_items(match.group(1), query, reply)
            if method == "POST" and path == "/v1/products":
                return self._create_product(body, reply, live)
            if method == "POST" and path == "/v1/prices":
                return self._create_price(body, reply, live)
            if method == "POST" and path == "/v1/payment_links":
                return self._create_link(body, reply, live)
            return self._error(404, reply, "Unrecognized request URL (%s: %s)." % (method, path))

    @staticmethod
    def _error(status, reply, message, code=None, param=None):
        error = {"message": message, "type": "invalid_request_error"}
        if code:
            error["code"] = code
        if param:
            error["param"] = param
        return status, reply, {"error": error}

    def _check(self, pairs, patterns, required, reply):
        seen = {}
        for name, value in pairs:
            if not any(re.match(p, name) for p in patterns):
                return None, self._error(400, reply, "Received unknown parameter: %s" % name, param=name)
            if name in seen and not name.endswith("[]"):
                return None, self._error(400, reply, "Received duplicate parameter: %s" % name, param=name)
            seen[name] = value
        for name in required:
            if name not in seen:
                return None, self._error(400, reply, "Missing required param: %s." % name, param=name)
        return seen, None

    def _price_view(self, price, expand_product):
        view = json.loads(json.dumps(price))
        if expand_product and price["product"] in self.products:
            view["product"] = json.loads(json.dumps(self.products[price["product"]]))
        return view

    def _page(self, items, query, reply, url):
        params = dict(query)
        limit = int(params.get("limit", "10"))
        if limit < 1 or limit > 100:
            return self._error(400, reply, "Invalid integer: %s" % params.get("limit"), param="limit")
        if "starting_after" in params:
            ids = [item["id"] for item in items]
            if params["starting_after"] not in ids:
                return self._error(400, reply, "No such object: %s" % params["starting_after"], param="starting_after")
            items = items[ids.index(params["starting_after"]) + 1:]
        page = items[:limit]
        return 200, reply, {"object": "list", "url": url, "has_more": len(items) > limit, "data": page}

    def _list_prices(self, query, reply):
        _, problem = self._check(query, PRICE_LIST_PATTERNS, [], reply)
        if problem:
            return problem
        params = {}
        for name, value in query:
            params.setdefault(name, []).append(value)
        expand = params.get("expand[]", [])
        if any(value != "data.product" for value in expand):
            return self._error(400, reply, "This property cannot be expanded (%s)." % expand[0])
        found = [p for p in reversed(self.prices) if p["lookup_key"] in params.get("lookup_keys[]", [p["lookup_key"]])]
        if "active" in params:
            found = [p for p in found if str(p["active"]).lower() == params["active"][0]]
        views = [self._price_view(p, bool(expand)) for p in found]
        paging = [(k, v[0]) for k, v in params.items() if k in ("limit", "starting_after")]
        return self._page(views, paging, reply, "/v1/prices")

    def _get_product(self, product_id, reply):
        product = self.products.get(product_id)
        if product is None:
            return self._error(404, reply, "No such product: '%s'" % product_id, code="resource_missing", param="id")
        return 200, reply, product

    def _create_product(self, body, reply, live):
        seen, problem = self._check(body, PRODUCT_PATTERNS, ["name"], reply)
        if problem:
            return problem
        product_id = seen.get("id") or self._new_id("prod")
        if product_id in self.products:
            return self._error(400, reply, "Product already exists.", code="resource_already_exists")
        product = {"id": product_id, "object": "product", "active": True, "name": seen["name"], "livemode": live,
                   "metadata": dict((k[len("metadata["):-1], v) for k, v in seen.items() if k.startswith("metadata["))}
        self.products[product_id] = product
        return 200, reply, product

    def _create_price(self, body, reply, live):
        seen, problem = self._check(
            body, PRICE_PATTERNS, ["currency", "product", "unit_amount", "recurring[interval]"], reply)
        if problem:
            return problem
        if not re.match(r"^[a-z]{3}$", seen["currency"]):
            return self._error(400, reply, "Invalid currency: %s. Currency codes must be lowercase." % seen["currency"], param="currency")
        if not re.match(r"^[0-9]+$", seen["unit_amount"]):
            return self._error(400, reply, "Invalid integer: %s" % seen["unit_amount"], param="unit_amount")
        if seen["recurring[interval]"] not in ("day", "week", "month", "year"):
            return self._error(400, reply, "Invalid interval", param="recurring[interval]")
        if seen.get("transfer_lookup_key", "false") not in ("true", "false"):
            return self._error(400, reply, "Invalid boolean", param="transfer_lookup_key")
        if seen["product"] not in self.products:
            return self._error(400, reply, "No such product: '%s'" % seen["product"], code="resource_missing", param="product")
        key = seen.get("lookup_key")
        if key:
            holders = [p for p in self.prices if p["lookup_key"] == key]
            if holders and seen.get("transfer_lookup_key") != "true":
                return self._error(400, reply, "A price with lookup_key %s already exists. Set transfer_lookup_key to move it." % key, param="lookup_key")
            for holder in holders:
                holder["lookup_key"] = None
        price = {
            "id": self._new_id("price"), "object": "price", "active": True, "currency": seen["currency"],
            "unit_amount": int(seen["unit_amount"]), "lookup_key": key, "product": seen["product"], "type": "recurring",
            "recurring": {"interval": seen["recurring[interval]"], "interval_count": 1, "usage_type": "licensed"},
            "metadata": dict((k[len("metadata["):-1], v) for k, v in seen.items() if k.startswith("metadata[")),
            "livemode": live,
        }
        self.prices.append(price)
        return 200, reply, price

    def _create_link(self, body, reply, live):
        seen, problem = self._check(
            body, LINK_PATTERNS, ["line_items[0][price]", "line_items[0][quantity]"], reply)
        if problem:
            return problem
        for name, allowed in (("allow_promotion_codes", ("true", "false")),
                              ("billing_address_collection", ("auto", "required")),
                              ("after_completion[type]", ("hosted_confirmation", "redirect"))):
            if name in seen and seen[name] not in allowed:
                return self._error(400, reply, "Invalid value for %s" % name, param=name)
        message = seen.get("after_completion[hosted_confirmation][custom_message]", "")
        if len(message) > 500:
            return self._error(400, reply, "custom_message must be 500 characters or fewer", param="after_completion")
        price_id = seen["line_items[0][price]"]
        if not any(p["id"] == price_id for p in self.prices):
            return self._error(400, reply, "No such price: '%s'" % price_id, code="resource_missing", param="line_items[0][price]")
        link = self.add_link(
            metadata=dict((k[len("metadata["):-1], v) for k, v in seen.items() if k.startswith("metadata[")),
            price_id=price_id, live=live)
        return 200, reply, link

    def _list_links(self, query, reply):
        _, problem = self._check(query, LINK_LIST_PATTERNS, [], reply)
        if problem:
            return problem
        params = dict(query)
        found = [entry["link"] for entry in reversed(self.links)]
        if "active" in params:
            found = [link for link in found if str(link["active"]).lower() == params["active"]]
        return self._page(json.loads(json.dumps(found)), query, reply, "/v1/payment_links")

    def _line_items(self, link_id, query, reply):
        _, problem = self._check(query, LINE_ITEM_LIST_PATTERNS, [], reply)
        if problem:
            return problem
        for entry in self.links:
            if entry["link"]["id"] == link_id:
                items = []
                for price in self.prices:
                    if price["id"] == entry["price_id"]:
                        items.append({"id": "li_mock_001", "object": "item", "quantity": 1,
                                      "price": json.loads(json.dumps(price))})
                return 200, reply, {"object": "list", "has_more": False, "data": items}
        return self._error(404, reply, "No such payment link: '%s'" % link_id, code="resource_missing")


# ------------------------------------------------------------ test helpers


class Result(object):
    def __init__(self, code, out, err):
        self.code = code
        self.out = out
        self.err = err

    @property
    def last_line(self):
        lines = self.out.rstrip("\n").split("\n")
        return lines[-1] if lines else ""


class MockCase(unittest.TestCase):
    key = TEST_KEY

    def setUp(self):
        self.mock = MockStripe()
        self.mock.start()
        self.addCleanup(self.mock.stop)
        self.home = tempfile.mkdtemp(prefix="checkout-test-home-")
        self.addCleanup(shutil.rmtree, self.home, True)

    def env(self, key="default", base="default", **extra):
        env = {"HOME": self.home}
        if key == "default":
            key = self.key
        if key is not None:
            env["STRIPE_SECRET_KEY"] = key
        if base == "default":
            base = self.mock.base
        if base is not None:
            env["STRIPE_API_BASE"] = base
        env.update(extra)
        return env

    def run_cli(self, *args, **kw):
        env = kw.pop("env", None)
        send = kw.pop("send", None)
        env = self.env() if env is None else env
        out, err = io.StringIO(), io.StringIO()
        code = cc.main(list(args), environ=env, stdout=out, stderr=err, send=send)
        result = Result(code, out.getvalue(), err.getvalue())
        self.assert_no_secrets(result.out, result.err)
        return result

    def assert_no_secrets(self, *texts):
        for text in texts:
            for secret in ALL_FAKE_KEYS:
                self.assertFalse(secret in text, "a key leaked into the output")
            self.assertIsNone(re.search(r"(sk|rk|pk)_(test|live)_[A-Za-z0-9]", text),
                              "something shaped like a key is in the output")

    def assert_no_posts(self):
        self.assertEqual(self.mock.posts(), [], "a POST was sent")

    def first_run(self, *args):
        result = self.run_cli(*args)
        self.assertEqual(result.code, 0, result.err)
        return result


class LiveCase(MockCase):
    """A live key can only be used against api.stripe.com, so these tests inject a
    transport that takes the script's https://api.stripe.com requests and delivers
    them to the fake on 127.0.0.1. The live key never goes anywhere else."""

    key = LIVE_KEY

    def setUp(self):
        MockCase.setUp(self)
        self.urls = []

    def send(self, method, url, headers, body):
        self.urls.append(url)
        if not url.startswith("https://api.stripe.com/"):
            raise AssertionError("the script should believe it is talking to api.stripe.com")
        return cc._urllib_send(method, self.mock.base + url[len("https://api.stripe.com"):], headers, body)

    def run_live(self, *args, **kw):
        key = kw.pop("key", self.key)
        return self.run_cli(*args, env=self.env(key=key, base=None), send=self.send)


# ------------------------------------------------------------ pure functions


class AmountTests(unittest.TestCase):
    def test_conversion_table(self):
        table = [
            ("12.00", "SGD", 1200), ("12", "sgd", 1200), ("0.50", "USD", 50), ("19.99", "EUR", 1999),
            ("1000", "JPY", 1000), ("1000.0", "JPY", 1000), ("1000", "KRW", 1000), ("5000", "VND", 5000),
            ("300", "XAF", 300), ("300", "CLP", 300),
            ("500", "ISK", 50000), ("500", "UGX", 50000),
            ("12.5", "SGD", 1250), ("0.01", "GBP", 1), ("12.340", "SGD", 1234), ("00012", "SGD", 1200),
        ]
        for amount, currency, expected in table:
            with self.subTest(amount=amount, currency=currency):
                result = cc.to_minor_units(amount, currency)
                self.assertEqual(result, expected)
                self.assertIsInstance(result, int)

    def test_decimal_is_used_never_float(self):
        # With float arithmetic each of these comes out one cent short (for example 0.29 * 100).
        for amount, expected in (("0.29", 29), ("1.15", 115), ("4.35", 435), ("0.57", 57), ("8.20", 820)):
            with self.subTest(amount=amount):
                self.assertEqual(cc.to_minor_units(amount, "USD"), expected)

    def test_refused_values(self):
        refused = [
            ("12.5", "JPY"), ("1000.5", "KRW"), ("500.5", "ISK"), ("12.005", "SGD"), ("0.001", "USD"),
            ("1", "KWD"), ("1.234", "KWD"), ("1", "BHD"), ("1", "jod"), ("1", "OMR"), ("1", "TND"),
            ("0", "SGD"), ("0.00", "SGD"), ("-1", "SGD"), ("abc", "SGD"), ("", "SGD"), ("NaN", "SGD"),
            ("Infinity", "SGD"), ("1e3", "SGD"), ("1,50", "SGD"), ("12.", "SGD"), (".5", "SGD"),
            ("12", "SG"), ("12", "SGDD"), ("12", "S1D"), ("12", ""), ("9" * 13, "SGD"),
        ]
        for amount, currency in refused:
            with self.subTest(amount=amount, currency=currency):
                with self.assertRaises(cc.UsageError):
                    cc.to_minor_units(amount, currency)

    def test_three_decimal_message_says_why(self):
        with self.assertRaises(cc.UsageError) as caught:
            cc.to_minor_units("1", "KWD")
        self.assertIn("three-decimal", str(caught.exception))

    def test_format_minor(self):
        self.assertEqual(cc.format_minor(1200, "sgd"), "12.00")
        self.assertEqual(cc.format_minor(5, "usd"), "0.05")
        self.assertEqual(cc.format_minor(1000, "jpy"), "1000")
        self.assertEqual(cc.format_minor(50000, "isk"), "500")


class BaseCheckTests(unittest.TestCase):
    def test_accepted_bases(self):
        for base, host in (("https://api.stripe.com", "api.stripe.com"), ("https://api.stripe.com/", "api.stripe.com"),
                           ("https://API.STRIPE.COM", "api.stripe.com"), ("http://127.0.0.1:5000", "127.0.0.1"),
                           ("http://localhost:8080", "localhost"), ("http://127.0.0.1", "127.0.0.1")):
            with self.subTest(base=base):
                normalised, found = cc.check_base(base)
                self.assertEqual(found, host)
                self.assertFalse(normalised.endswith("/"))

    def test_refused_bases(self):
        for base in ("http://api.stripe.com", "https://evil.example.com", "https://api.stripe.com.evil.com",
                     "http://127.0.0.1@evil.com", "https://api.stripe.com@evil.com", "http://127.0.0.2:80",
                     "ftp://127.0.0.1", "https://api.stripe.com:8443", "http://127.0.0.1:5000/v1",
                     "https://user:pw@api.stripe.com", "http://[::1]:80", "https://", "", "api.stripe.com",
                     "http://127.0.0.1:99999", "https://api.stripe.com/?x=1", "http://localhost.evil.com"):
            with self.subTest(base=base):
                with self.assertRaises(cc.UsageError):
                    cc.check_base(base)


class KeyTests(MockCase):
    def test_missing_key_gives_exit_5_and_sends_nothing(self):
        result = self.run_cli(env=self.env(key=None), send=forbidden_send)
        self.assertEqual(result.code, 5)
        self.assertIn("STRIPE_SECRET_KEY", result.err)
        self.assertIn("ranklore_api_key", result.err)
        self.assertEqual(self.mock.requests, [])

    def test_empty_env_and_empty_file_give_exit_5(self):
        os.makedirs(os.path.join(self.home, ".config", "stripe"))
        with open(os.path.join(self.home, ".config", "stripe", "ranklore_api_key"), "w") as handle:
            handle.write("\n")
        result = self.run_cli(env=self.env(key="   "), send=forbidden_send)
        self.assertEqual(result.code, 5)

    def test_unusable_keys_give_exit_5(self):
        for bad in ("pk_test_FAKEPUBLISHABLE", "sk_org_FAKEORGKEY", "garbage", "sk_test_", "sk_test_FAKE KEY",
                    "sk_prod_FAKEKEY0009", "whsec_FAKESECRET"):
            with self.subTest(kind=bad.split("_")[0]):
                result = self.run_cli(env=self.env(key=bad), send=forbidden_send)
                self.assertEqual(result.code, 5)
                self.assertNotIn(bad, result.err)
                self.assertNotIn(bad, result.out)

    def test_key_file_first_line_is_used_and_env_wins(self):
        os.makedirs(os.path.join(self.home, ".config", "stripe"))
        with open(os.path.join(self.home, ".config", "stripe", "ranklore_api_key"), "w") as handle:
            handle.write(RESTRICTED_TEST_KEY + "\nthis second line is ignored\n")
        result = self.run_cli("--dry-run", env=self.env(key=None))
        self.assertEqual(result.code, 0, result.err)
        self.assertEqual(self.mock.requests[0]["headers"]["authorization"], "Bearer " + RESTRICTED_TEST_KEY)
        self.mock.forget_requests()
        result = self.run_cli("--dry-run", env=self.env(key=TEST_KEY))
        self.assertEqual(result.code, 0, result.err)
        self.assertEqual(self.mock.requests[0]["headers"]["authorization"], "Bearer " + TEST_KEY)

    def test_only_the_kind_is_printed(self):
        for key, kind in ((TEST_KEY, "sk_test"), (RESTRICTED_TEST_KEY, "rk_test")):
            with self.subTest(kind=kind):
                result = self.run_cli("--dry-run", env=self.env(key=key))
                self.assertEqual(result.code, 0, result.err)
                self.assertIn("key kind:          %s " % kind, result.out)
                self.assertNotIn(key[len(kind):], result.out)


class LiveKindTests(LiveCase):
    def test_live_kinds_are_printed_and_gated(self):
        for key, kind in ((LIVE_KEY, "sk_live"), (RESTRICTED_LIVE_KEY, "rk_live")):
            with self.subTest(kind=kind):
                self.mock.forget_requests()
                result = self.run_live(key=key)
                self.assertEqual(result.code, 2)
                self.assertIn("key kind:          %s (LIVE mode)" % kind, result.out)
                self.assert_no_posts()


# ------------------------------------------------------------ the whole flow


class IdentityTests(MockCase):
    def test_identity_is_printed(self):
        result = self.run_cli("--dry-run")
        self.assertEqual(result.code, 0, result.err)
        self.assertIn("account:           acct_MOCK0001", result.out)
        self.assertIn("display name:      Ranklore Pte Ltd", result.out)
        self.assertIn("country:           SG", result.out)
        self.assertIn("default currency:  sgd", result.out)

    def test_identity_is_the_first_request(self):
        self.run_cli("--dry-run")
        self.assertEqual(self.mock.requests[0]["method"], "GET")
        self.assertEqual(self.mock.requests[0]["path"], "/v1/account")

    def test_wrong_account_is_refused_with_exit_3_before_anything_else(self):
        self.mock.account = account_object("Acme Widgets Ltd")
        result = self.run_cli()
        self.assertEqual(result.code, 3)
        self.assertIn("acct_MOCK0001", result.err)
        self.assertIn("ranklore", result.err)
        self.assertIn("Acme Widgets Ltd", result.err)
        self.assertEqual(self.mock.paths(), ["/v1/account"])
        self.assert_no_posts()

    def test_account_with_no_names_is_refused(self):
        self.mock.account = account_object("x", where="none")
        result = self.run_cli()
        self.assertEqual(result.code, 3)
        self.assert_no_posts()

    def test_expect_name_override_is_case_insensitive(self):
        self.mock.account = account_object("Acme Widgets Ltd")
        result = self.run_cli("--expect-name", "ACME", "--dry-run")
        self.assertEqual(result.code, 0, result.err)

    def test_any_of_the_account_names_can_match(self):
        for where in ("dashboard", "profile", "company"):
            with self.subTest(where=where):
                self.mock.account = account_object("RANKLORE Pte Ltd", where=where)
                self.mock.forget_requests()
                result = self.run_cli("--dry-run")
                self.assertEqual(result.code, 0, result.err)

    def test_empty_expect_name_is_a_usage_error(self):
        for value in ("", "   "):
            with self.subTest(value=value):
                result = self.run_cli("--expect-name", value, env=self.env(), send=forbidden_send)
                self.assertEqual(result.code, 64)
        self.assertEqual(self.mock.requests, [])


class CreateFlowTests(MockCase):
    def test_first_run_creates_product_price_and_link_and_ends_with_the_url(self):
        result = self.first_run()
        self.assertEqual(self.mock.paths("POST"), ["/v1/products", "/v1/prices", "/v1/payment_links"])
        link = self.mock.links[0]["link"]
        self.assertEqual(result.last_line, link["url"])
        self.assertTrue(result.last_line.startswith("https://buy.stripe.com/"))
        self.assertIn(link["id"], result.out)
        self.assertEqual(result.err, "")
        self.assertEqual(self.mock.links[0]["price_id"], self.mock.prices[0]["id"])

    def test_requests_are_form_encoded_with_bearer_auth(self):
        self.first_run()
        for record in self.mock.posts():
            self.assertEqual(record["headers"]["content-type"], "application/x-www-form-urlencoded")
            self.assertEqual(record["headers"]["authorization"], "Bearer " + TEST_KEY)
            record["raw"].decode("ascii")
            self.assertEqual(urllib.parse.parse_qsl(record["raw"].decode("ascii"), keep_blank_values=True), record["body"])
        for record in self.mock.requests:
            self.assertEqual(record["headers"]["authorization"], "Bearer " + TEST_KEY)
            if record["method"] == "GET":
                self.assertEqual(record["raw"], b"")

    def test_product_body(self):
        self.first_run()
        record = self.mock.posts()[0]
        self.assertEqual(record["path"], "/v1/products")
        self.assertEqual(self.mock.form(record), {
            "id": "purrscribe_cloud", "name": "Purrscribe Cloud",
            "metadata[app]": "purrscribe", "metadata[plan]": "cloud_monthly",
        })

    def test_price_body(self):
        self.first_run()
        record = self.mock.posts()[1]
        self.assertEqual(record["path"], "/v1/prices")
        self.assertEqual(self.mock.form(record), {
            "product": "purrscribe_cloud", "currency": "sgd", "unit_amount": "1200",
            "recurring[interval]": "month", "lookup_key": "purrscribe_cloud_monthly",
            "metadata[app]": "purrscribe", "metadata[plan]": "cloud_monthly",
        })

    def test_payment_link_body(self):
        self.first_run()
        price_id = self.mock.prices[0]["id"]
        record = self.mock.posts()[2]
        self.assertEqual(record["path"], "/v1/payment_links")
        form = self.mock.form(record)
        self.assertEqual(form, {
            "line_items[0][price]": price_id,
            "line_items[0][quantity]": "1",
            "allow_promotion_codes": "true",
            "billing_address_collection": "auto",
            "after_completion[type]": "hosted_confirmation",
            "after_completion[hosted_confirmation][custom_message]": cc.THANK_YOU_MESSAGE,
            "metadata[app]": "purrscribe",
            "metadata[plan]": "cloud_monthly",
            "subscription_data[metadata][app]": "purrscribe",
            "subscription_data[metadata][plan]": "cloud_monthly",
        })

    def test_thank_you_message_is_plain_and_within_the_limit(self):
        message = cc.THANK_YOU_MESSAGE
        self.assertLess(len(message), 500)
        self.assertNotIn(EM_DASH, message)
        self.assertNotIn(chr(0x2013), message)
        self.assertIn("Thank you", message)
        self.assertIn("Purrscribe Cloud", message)
        # Receipts and cancelling depend on Dashboard settings nobody has checked, so the message promises neither.
        for word in ("receipt", "email", "reply", "cancel", "refund"):
            self.assertNotIn(word, message.lower())

    def test_lookup_requests(self):
        self.first_run()
        gets = [r for r in self.mock.requests if r["method"] == "GET"]
        self.assertEqual([r["path"] for r in gets],
                         ["/v1/account", "/v1/prices", "/v1/payment_links", "/v1/products/purrscribe_cloud"])
        self.assertEqual(gets[1]["query"],
                         [("lookup_keys[]", "purrscribe_cloud_monthly"), ("active", "true"), ("expand[]", "data.product")])
        self.assertEqual(gets[2]["query"], [("active", "true"), ("limit", "100")])

    def test_currency_and_amount_flags_are_used(self):
        self.first_run("--amount", "15.50", "--currency", "usd")
        form = self.mock.form(self.mock.posts()[1])
        self.assertEqual(form["currency"], "usd")
        self.assertEqual(form["unit_amount"], "1550")

    def test_zero_decimal_currency_is_not_multiplied(self):
        self.first_run("--amount", "1800", "--currency", "JPY")
        form = self.mock.form(self.mock.posts()[1])
        self.assertEqual(form["currency"], "jpy")
        self.assertEqual(form["unit_amount"], "1800")

    def test_a_test_key_needs_no_yes_live(self):
        for key in (TEST_KEY, RESTRICTED_TEST_KEY):
            with self.subTest(key=key[:7]):
                fresh = MockStripe()
                fresh.start()
                self.addCleanup(fresh.stop)
                result = self.run_cli(env=self.env(key=key, base=fresh.base))
                self.assertEqual(result.code, 0, result.err)
                self.assertEqual(len(fresh.posts()), 3)


class IdempotencyTests(MockCase):
    def test_second_run_makes_zero_posts_and_prints_the_same_url(self):
        first = self.first_run()
        self.mock.forget_requests()
        second = self.run_cli()
        self.assertEqual(second.code, 0, second.err)
        self.assert_no_posts()
        self.assertEqual(second.last_line, first.last_line)
        self.assertIn("already exists", second.out)
        self.assertEqual(len(self.mock.products), 1)
        self.assertEqual(len(self.mock.prices), 1)
        self.assertEqual(len(self.mock.links), 1)

    def test_many_runs_never_make_a_second_copy(self):
        self.first_run()
        for _ in range(3):
            self.assertEqual(self.run_cli().code, 0)
        self.assertEqual((len(self.mock.products), len(self.mock.prices), len(self.mock.links)), (1, 1, 1))

    def test_a_failed_run_is_finished_by_the_next_one(self):
        self.mock.overrides.append(Override("POST", "/v1/prices", 400, {"error": {"message": "boom"}}, times=1))
        failed = self.run_cli()
        self.assertEqual(failed.code, 4)
        self.assertEqual(self.mock.paths("POST"), ["/v1/products", "/v1/prices"])
        self.mock.forget_requests()
        finished = self.run_cli()
        self.assertEqual(finished.code, 0, finished.err)
        self.assertEqual(self.mock.paths("POST"), ["/v1/prices", "/v1/payment_links"])
        self.assertEqual(len(self.mock.products), 1)

    def test_missing_link_alone_is_recreated_for_the_existing_price(self):
        self.first_run()
        self.mock.links[:] = []
        self.mock.forget_requests()
        result = self.run_cli()
        self.assertEqual(result.code, 0, result.err)
        self.assertEqual(self.mock.paths("POST"), ["/v1/payment_links"])
        self.assertEqual(self.mock.links[0]["price_id"], self.mock.prices[0]["id"])
        self.assertEqual(len(self.mock.prices), 1)

    def test_inactive_links_and_other_apps_are_ignored(self):
        self.first_run()
        self.mock.links[0]["link"]["active"] = False
        self.mock.add_link(metadata={"app": "ranklore", "plan": "cloud_monthly"}, price_id=self.mock.prices[0]["id"])
        self.mock.add_link(metadata={"app": "purrscribe", "plan": "other_plan"}, price_id=self.mock.prices[0]["id"])
        self.mock.forget_requests()
        result = self.run_cli()
        self.assertEqual(result.code, 0, result.err)
        self.assertEqual(self.mock.paths("POST"), ["/v1/payment_links"])

    def test_link_found_on_the_second_page(self):
        first = self.first_run()
        for _ in range(120):
            self.mock.add_link(metadata={"app": "ranklore"})
        self.mock.forget_requests()
        result = self.run_cli()
        self.assertEqual(result.code, 0, result.err)
        self.assert_no_posts()
        self.assertEqual(result.last_line, first.last_line)
        pages = [r for r in self.mock.requests if r["path"] == "/v1/payment_links"]
        self.assertEqual(len(pages), 2)
        self.assertIn("starting_after", dict(pages[1]["query"]))

    def test_link_for_another_price_is_not_reused(self):
        self.first_run()
        other = self.mock.add_price(amount=900, lookup_key=None)
        self.mock.links[0]["price_id"] = other["id"]
        self.mock.forget_requests()
        result = self.run_cli()
        self.assertEqual(result.code, 0, result.err)
        self.assertEqual(self.mock.paths("POST"), ["/v1/payment_links"])


class PriceMismatchTests(MockCase):
    def test_different_amount_stops_with_exit_6_and_no_posts(self):
        self.first_run()
        old_price = self.mock.prices[0]["id"]
        self.mock.forget_requests()
        result = self.run_cli("--amount", "15.00")
        self.assertEqual(result.code, 6)
        self.assert_no_posts()
        self.assertIn(old_price, result.err)
        self.assertIn("SGD 12.00", result.err)
        self.assertIn("SGD 15.00", result.err)
        self.assertIn("--new-price", result.err)

    def test_different_currency_stops(self):
        self.first_run()
        self.mock.forget_requests()
        result = self.run_cli("--currency", "USD")
        self.assertEqual(result.code, 6)
        self.assert_no_posts()

    def test_different_interval_stops(self):
        self.mock.add_product()
        self.mock.add_price(amount=1200, currency="sgd", interval="year")
        result = self.run_cli()
        self.assertEqual(result.code, 6)
        self.assert_no_posts()
        self.assertIn("year", result.err)

    def test_different_interval_count_stops(self):
        self.mock.add_product()
        self.mock.add_price(amount=1200, currency="sgd", interval="month", interval_count=3)
        result = self.run_cli()
        self.assertEqual(result.code, 6)
        self.assert_no_posts()

    def test_new_price_flag_creates_a_new_price_and_link_and_deactivates_nothing(self):
        first = self.first_run()
        old_price = self.mock.prices[0]
        old_link = self.mock.links[0]["link"]
        self.mock.forget_requests()
        result = self.run_cli("--amount", "15.00", "--new-price")
        self.assertEqual(result.code, 0, result.err)
        self.assertEqual(self.mock.paths("POST"), ["/v1/prices", "/v1/payment_links"])
        price_form = self.mock.form(self.mock.posts()[0])
        self.assertEqual(price_form["unit_amount"], "1500")
        self.assertEqual(price_form["transfer_lookup_key"], "true")
        self.assertEqual(price_form["product"], "purrscribe_cloud")
        self.assertEqual(price_form["lookup_key"], "purrscribe_cloud_monthly")
        new_price = self.mock.prices[-1]
        link_form = self.mock.form(self.mock.posts()[1])
        self.assertEqual(link_form["line_items[0][price]"], new_price["id"])
        self.assertNotEqual(result.last_line, first.last_line)
        self.assertTrue(old_price["active"])
        self.assertTrue(old_link["active"])
        self.assertEqual(len(self.mock.products), 1)

    def test_after_new_price_the_new_link_is_the_one_returned(self):
        first = self.first_run()
        second = self.run_cli("--amount", "15.00", "--new-price")
        self.assertEqual(second.code, 0, second.err)
        self.mock.forget_requests()
        third = self.run_cli("--amount", "15.00")
        self.assertEqual(third.code, 0, third.err)
        self.assert_no_posts()
        self.assertEqual(third.last_line, second.last_line)
        self.assertNotEqual(third.last_line, first.last_line)
        again_old = self.run_cli("--amount", "12.00")
        self.assertEqual(again_old.code, 6)

    def test_new_price_flag_does_nothing_when_the_price_already_matches(self):
        first = self.first_run()
        self.mock.forget_requests()
        result = self.run_cli("--new-price")
        self.assertEqual(result.code, 0, result.err)
        self.assert_no_posts()
        self.assertEqual(result.last_line, first.last_line)

    def test_stale_link_without_a_keyed_price_needs_a_decision(self):
        self.mock.add_link(price_id="price_mock_gone")
        result = self.run_cli()
        self.assertEqual(result.code, 6)
        self.assert_no_posts()
        self.assertIn("--new-price", result.err)
        self.assertIn("plink_mock_", result.err)

    def test_new_price_flag_overrides_the_stale_link_stop(self):
        self.mock.add_link(price_id="price_mock_gone")
        result = self.run_cli("--new-price")
        self.assertEqual(result.code, 0, result.err)
        self.assertEqual(self.mock.paths("POST"), ["/v1/products", "/v1/prices", "/v1/payment_links"])
        self.assertEqual(self.mock.form(self.mock.posts()[1])["transfer_lookup_key"], "true")

    def test_archived_price_holding_the_key_is_handled_with_new_price(self):
        self.mock.add_product()
        self.mock.add_price(amount=900, active=False)
        stopped = self.run_cli()
        self.assertEqual(stopped.code, 4)
        self.assertIn("lookup_key", stopped.err)
        self.mock.forget_requests()
        result = self.run_cli("--new-price")
        self.assertEqual(result.code, 0, result.err)

    def test_archived_product_needs_a_decision(self):
        self.mock.add_product(active=False)
        result = self.run_cli()
        self.assertEqual(result.code, 6)
        self.assert_no_posts()
        self.assertIn("archived", result.err)


class DryRunTests(MockCase):
    def test_dry_run_sends_no_post_and_prints_the_requests(self):
        result = self.run_cli("--dry-run")
        self.assertEqual(result.code, 0, result.err)
        self.assert_no_posts()
        for path in ("POST /v1/products", "POST /v1/prices", "POST /v1/payment_links"):
            self.assertIn(path, result.out)
        for field in ("  id=purrscribe_cloud", "  unit_amount=1200", "  currency=sgd", "  recurring[interval]=month",
                      "  lookup_key=purrscribe_cloud_monthly", "  line_items[0][quantity]=1",
                      "  metadata[app]=purrscribe", "  subscription_data[metadata][plan]=cloud_monthly"):
            self.assertIn(field, result.out)
        self.assertEqual(self.mock.links, [])
        self.assertFalse(result.last_line.startswith("https://"))

    def test_dry_run_still_checks_the_account_first(self):
        self.mock.account = account_object("Acme Widgets Ltd")
        result = self.run_cli("--dry-run")
        self.assertEqual(result.code, 3)
        self.assertEqual(self.mock.paths(), ["/v1/account"])

    def test_dry_run_after_a_real_run_prints_the_existing_url(self):
        first = self.first_run()
        self.mock.forget_requests()
        result = self.run_cli("--dry-run")
        self.assertEqual(result.code, 0, result.err)
        self.assert_no_posts()
        self.assertEqual(result.last_line, first.last_line)

    def test_dry_run_shows_a_new_price_plan(self):
        self.first_run()
        self.mock.forget_requests()
        result = self.run_cli("--dry-run", "--amount", "15", "--new-price")
        self.assertEqual(result.code, 0, result.err)
        self.assert_no_posts()
        self.assertIn("  transfer_lookup_key=true", result.out)
        self.assertIn("<id from the step above>", result.out)

    def test_dry_run_blocks_posts_even_if_the_planner_were_wrong(self):
        client = cc.Client(self.mock.base, TEST_KEY, allow_post=False)
        with self.assertRaises(cc.PostBlocked):
            client.post("/v1/products", [("name", "x")])
        self.assertEqual(self.mock.requests, [])


class LiveGateTests(LiveCase):
    def test_live_key_without_yes_live_makes_zero_posts_and_exits_2(self):
        result = self.run_live()
        self.assertEqual(result.code, 2)
        self.assert_no_posts()
        self.assertIn("POST /v1/products", result.out)
        self.assertIn("POST /v1/prices", result.out)
        self.assertIn("POST /v1/payment_links", result.out)
        self.assertIn("  unit_amount=1200", result.out)
        self.assertIn("--yes-live", result.err)
        self.assertEqual(self.mock.paths()[0], "/v1/account")
        self.assertEqual(self.mock.products, {})
        self.assertEqual(self.mock.prices, [])
        self.assertEqual(self.mock.links, [])

    def test_live_key_with_yes_live_creates_everything(self):
        result = self.run_live("--amount", "12", "--yes-live")
        self.assertEqual(result.code, 0, result.err)
        self.assertEqual(self.mock.paths("POST"), ["/v1/products", "/v1/prices", "/v1/payment_links"])
        self.assertEqual(result.last_line, self.mock.links[0]["link"]["url"])
        for record in self.mock.requests:
            self.assertEqual(record["headers"]["authorization"], "Bearer " + LIVE_KEY)
        self.assertTrue(all(url.startswith("https://api.stripe.com/") for url in self.urls))

    def test_live_second_run_needs_no_yes_live_because_nothing_is_created(self):
        first = self.run_live("--amount", "12", "--yes-live")
        self.mock.forget_requests()
        second = self.run_live("--amount", "12")
        self.assertEqual(second.code, 0, second.err)
        self.assert_no_posts()
        self.assertEqual(second.last_line, first.last_line)

    def test_dry_run_wins_over_yes_live(self):
        result = self.run_live("--dry-run", "--yes-live")
        self.assertEqual(result.code, 0, result.err)
        self.assert_no_posts()
        self.assertEqual(self.mock.links, [])

    def test_yes_live_without_amount_is_refused_before_anything_is_sent(self):
        result = self.run_live("--yes-live")
        self.assertEqual(result.code, 64)
        self.assertIn("--amount", result.err)
        self.assertEqual(self.mock.requests, [])
        self.assertEqual(self.mock.products, {})
        self.assertEqual(self.mock.prices, [])
        self.assertEqual(self.mock.links, [])

    def test_live_gate_asks_for_the_amount_only_when_it_was_left_out(self):
        without = self.run_live()
        self.assertEqual(without.code, 2)
        self.assertIn("--amount", without.err)
        self.assertIn("placeholder", without.out)
        given = self.run_live("--amount", "12")
        self.assertEqual(given.code, 2)
        self.assertNotIn("--amount", given.err)
        self.assertNotIn("placeholder", given.out)
        self.assert_no_posts()

    def test_live_gate_on_a_mismatch_still_stops_with_exit_6(self):
        self.run_live("--amount", "12", "--yes-live")
        self.mock.forget_requests()
        result = self.run_live("--amount", "15", "--yes-live")
        self.assertEqual(result.code, 6)
        self.assert_no_posts()

    def test_restricted_live_key_is_gated_too(self):
        result = self.run_live(key=RESTRICTED_LIVE_KEY)
        self.assertEqual(result.code, 2)
        self.assert_no_posts()

    def test_live_key_is_refused_for_any_other_base(self):
        for base in (self.mock.base, "http://localhost:1"):
            with self.subTest(base=base):
                result = self.run_cli(env=self.env(key=LIVE_KEY, base=base), send=forbidden_send)
                self.assertEqual(result.code, 64)
                self.assertIn("live key", result.err)
        self.assertEqual(self.mock.requests, [])

    def test_wrong_account_is_refused_with_a_live_key_too(self):
        self.mock.account = account_object("Acme Widgets Ltd")
        result = self.run_live("--amount", "12", "--yes-live")
        self.assertEqual(result.code, 3)
        self.assert_no_posts()


class BaseGuardTests(MockCase):
    def test_a_foreign_base_is_refused_and_nothing_is_sent(self):
        for base in ("https://evil.example.com", "http://api.stripe.com", "http://127.0.0.1@evil.com",
                     "https://api.stripe.com.evil.com"):
            with self.subTest(base=base):
                result = self.run_cli(env=self.env(base=base), send=forbidden_send)
                self.assertEqual(result.code, 64)
                self.assertIn("STRIPE_API_BASE", result.err)

    def test_redirects_are_never_followed(self):
        self.mock.overrides.append(Override(
            "GET", "/v1/account", 302, {}, headers={"Location": self.mock.base + "/v1/elsewhere"}))
        result = self.run_cli()
        self.assertEqual(result.code, 4)
        self.assertIn("redirect", result.err)
        self.assertNotIn("/v1/elsewhere", self.mock.paths())
        self.assertEqual(self.mock.paths(), ["/v1/account"])


class ErrorMappingTests(MockCase):
    def test_stripe_error_gives_exit_4_with_only_the_message_and_request_id(self):
        self.mock.overrides.append(Override(
            "POST", "/v1/prices", 400,
            {"error": {"message": "Invalid currency: xyz", "type": "invalid_request_error", "code": "CODE_SENTINEL",
                       "param": "PARAM_SENTINEL", "request_log_url": "https://dashboard.stripe.com/LOGURL_SENTINEL",
                       "doc_url": "https://stripe.com/docs/DOCURL_SENTINEL"}},
            headers={"Request-Id": "req_FAKE_ERROR_ID"}))
        result = self.run_cli()
        self.assertEqual(result.code, 4)
        self.assertIn("Invalid currency: xyz", result.err)
        self.assertIn("Stripe request id: req_FAKE_ERROR_ID", result.err)
        self.assertIn("POST /v1/prices", result.err)
        self.assertIn("HTTP 400", result.err)
        for sentinel in ("CODE_SENTINEL", "PARAM_SENTINEL", "LOGURL_SENTINEL", "DOCURL_SENTINEL", "invalid_request_error"):
            self.assertNotIn(sentinel, result.err + result.out)

    def test_nothing_after_the_failed_call_is_attempted(self):
        self.mock.overrides.append(Override("POST", "/v1/products", 402, {"error": {"message": "nope"}}))
        result = self.run_cli()
        self.assertEqual(result.code, 4)
        self.assertEqual(self.mock.paths("POST"), ["/v1/products"])

    def test_a_key_echoed_by_stripe_is_redacted(self):
        self.mock.keys = set(["sk_test_SOMEOTHERFAKE"])
        result = self.run_cli()
        self.assertEqual(result.code, 4)
        self.assertIn("Invalid API Key provided", result.err)
        self.assertIn("[redacted]", result.err)
        self.assertIn("HTTP 401", result.err)

    def test_a_partly_masked_key_in_a_message_is_redacted_too(self):
        self.mock.overrides.append(Override(
            "GET", "/v1/account", 401, {"error": {"message": "Invalid API Key provided: sk_test_********ABCD"}}))
        result = self.run_cli()
        self.assertEqual(result.code, 4)
        self.assertNotIn("ABCD", result.err)
        self.assertIn("[redacted]", result.err)

    def test_errors_without_a_json_body_do_not_print_the_body(self):
        self.mock.overrides.append(Override("GET", "/v1/prices", 500, b"<html>BODY_SENTINEL</html>"))
        result = self.run_cli()
        self.assertEqual(result.code, 4)
        self.assertIn("HTTP 500", result.err)
        self.assertNotIn("BODY_SENTINEL", result.err + result.out)

    def test_a_permission_error_on_the_account_check_is_exit_4(self):
        self.mock.overrides.append(Override(
            "GET", "/v1/account", 403, {"error": {"message": "The provided key does not have the required permissions."}},
            headers={"Request-Id": "req_FAKE_PERM"}))
        result = self.run_cli()
        self.assertEqual(result.code, 4)
        self.assertIn("required permissions", result.err)
        self.assertIn("req_FAKE_PERM", result.err)

    def test_a_reply_that_is_not_json_is_exit_4(self):
        self.mock.overrides.append(Override("GET", "/v1/account", 200, b"this is not json"))
        result = self.run_cli()
        self.assertEqual(result.code, 4)
        self.assertIn("not a JSON object", result.err)

    def test_an_unreachable_server_is_exit_4(self):
        result = self.run_cli(env=self.env(base="http://127.0.0.1:%d" % closed_port()))
        self.assertEqual(result.code, 4)
        self.assertIn("could not reach 127.0.0.1", result.err)

    def test_a_reply_without_an_id_is_exit_4(self):
        self.mock.overrides.append(Override("POST", "/v1/products", 200, {"object": "product"}))
        result = self.run_cli()
        self.assertEqual(result.code, 4)
        self.assertEqual(self.mock.paths("POST"), ["/v1/products"])


class CommandLineTests(MockCase):
    def test_bad_values_are_exit_64_and_nothing_is_sent(self):
        cases = [
            ["--bogus"], ["--amount", "abc"], ["--amount", "0"], ["--amount", "12.005"], ["--currency", "KWD"],
            ["--currency", "SG"], ["--yes"], ["--dry"], ["--amount"], ["--amount", "1000.5", "--currency", "JPY"],
        ]
        for args in cases:
            with self.subTest(args=" ".join(args)):
                result = self.run_cli(*args, env=self.env(), send=forbidden_send)
                self.assertEqual(result.code, 64)
                self.assertNotEqual(result.err, "")
        self.assertEqual(self.mock.requests, [])

    def test_exit_code_2_is_only_for_the_live_gate(self):
        result = self.run_cli("--bogus")
        self.assertNotEqual(result.code, 2)

    def test_help_exits_0_and_lists_the_flags(self):
        result = self.run_cli("-h")
        self.assertEqual(result.code, 0)
        for flag in ("--amount", "--currency", "--expect-name", "--dry-run", "--yes-live", "--new-price"):
            self.assertIn(flag, result.out)
        self.assertIn("exit codes", result.out)
        self.assertEqual(self.mock.requests, [])

    def test_no_output_contains_an_em_dash(self):
        for args in (["--dry-run"], ["-h"], [], ["--amount", "99"]):
            result = self.run_cli(*args)
            self.assertNotIn(EM_DASH, result.out + result.err)


class SourceTests(unittest.TestCase):
    def test_the_script_and_this_file_contain_no_em_dash(self):
        here = os.path.dirname(os.path.abspath(__file__))
        for name in ("create_checkout.py", "test_create_checkout.py"):
            with open(os.path.join(here, name), encoding="utf-8") as handle:
                self.assertFalse(EM_DASH in handle.read(), "an em dash is in " + name)

    def test_the_script_uses_only_the_standard_library(self):
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "create_checkout.py"), encoding="utf-8") as handle:
            imports = set(re.findall(r"^(?:import|from)\s+([A-Za-z0-9_]+)", handle.read(), re.M))
        allowed = set(["argparse", "http", "json", "os", "re", "ssl", "sys", "urllib", "decimal"])
        self.assertEqual(imports - allowed, set())


if __name__ == "__main__":
    unittest.main()
