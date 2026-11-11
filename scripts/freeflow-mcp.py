#!/usr/bin/env python3
"""Purrscribe MCP server: lets Claude Code, Claude Desktop or any MCP client read your dictation history,
dictionary and snippets, and add to them. Local only, stdio transport, standard library only.

Install once:  claude mcp add --scope user freeflow -- /usr/bin/env python3 /Applications/Purrscribe.app/Contents/Resources/freeflow-mcp.py
Run by hand:   python3 freeflow-mcp.py --selfcheck
"""
import json
import os
import plistlib
import sys
from datetime import datetime, timedelta

HOME = os.path.expanduser("~")
SUPPORT = os.path.join(HOME, "Library", "Application Support", "FreeFlow")
HISTORY_JSON = os.path.join(SUPPORT, "history.jsonl")
HISTORY_TXT = os.path.join(SUPPORT, "history.txt")
DICTIONARY = os.path.join(SUPPORT, "dictionary.txt")
SNIPPETS = os.path.join(SUPPORT, "snippets.txt")
PREFS = os.path.join(HOME, "Library", "Preferences", "com.momominibot.freeflow.plist")
PROTOCOL = "2025-06-18"


def prefs():
    try:
        with open(PREFS, "rb") as f:
            return plistlib.load(f)
    except Exception:
        return {}


def team_folder():
    p = prefs().get("teamFolder")
    return os.path.expanduser(p) if p else None


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def history():
    """Newest last. Falls back to the plain text log for dictations made before history.jsonl existed."""
    out = []
    for line in read(HISTORY_JSON).splitlines():
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    if not out:
        for line in read(HISTORY_TXT).splitlines():
            if len(line) > 18 and line[4] == "-" and line[10] == " ":
                out.append({"t": line[:16].replace(" ", "T"), "text": line[18:], "raw": "", "mode": "", "app": ""})
    return out


def entries(path):
    """Parses 'word' or 'wrong => right' / 'cue => expansion' lines."""
    out = []
    for raw in read(path).splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=>" in line:
            a, b = line.split("=>", 1)
            out.append({"from": a.strip(), "to": b.strip().replace("\\n", "\n")})
        else:
            out.append({"word": line})
    return out


def append_line(path, line):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write("\n" + line.strip() + "\n")


# ---- tools --------------------------------------------------------------

def t_search_history(query="", limit=20, days=None):
    q = (query or "").lower().strip()
    items = history()
    if days:
        since = (datetime.now() - timedelta(days=int(days))).isoformat()
        items = [h for h in items if h.get("t", "") >= since]
    if q:
        items = [h for h in items if q in h.get("text", "").lower() or q in h.get("raw", "").lower()]
    items = items[-int(limit):][::-1]
    return {"count": len(items), "dictations": [{k: h.get(k, "") for k in ("t", "app", "mode", "text", "raw")} for h in items]}


def t_recent_dictations(limit=10):
    return t_search_history("", limit)


def t_get_dictionary():
    team = team_folder()
    return {
        "personal": entries(DICTIONARY),
        "team": entries(os.path.join(team, "team-dictionary.txt")) if team else [],
        "team_folder": team,
    }


def t_get_snippets():
    team = team_folder()
    return {
        "personal": entries(SNIPPETS),
        "team": entries(os.path.join(team, "team-snippets.txt")) if team else [],
        "team_folder": team,
    }


def t_get_usage():
    p = prefs()
    by_app = {}
    for k, v in (p.get("wordsByApp", {}) or {}).items():
        try:
            by_app[k] = int(v)          # a count saved as text still counts
        except (TypeError, ValueError):
            continue
    today = datetime.now().strftime("%Y-%m-%d")
    words_today = p.get("wordsToday", 0) if p.get("wordsDay") == today else 0
    return {
        "words_today": words_today,
        "words_total": p.get("wordsTotal", 0),
        "top_apps": sorted(({"app": k, "words": v} for k, v in by_app.items()), key=lambda x: -x["words"])[:10],
        "cleanup_level": p.get("cleanupLevel", "medium"),
        "language": p.get("language", "en"),
    }


def t_workday_summary(days=1):
    """Minutes per app for the last N days from the workday notes. App names and minutes only: no window titles."""
    days = max(1, min(int(days), 14))
    folder = os.path.join(SUPPORT, "workday")
    on = bool(prefs().get("workdayOn", False))
    out = {"notes_are_on": on, "days": {}}
    if not os.path.isdir(folder):
        return out
    cutoff = (datetime.now() - timedelta(days=days - 1)).strftime("%Y-%m-%d")
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".jsonl") or name[:-6] < cutoff:
            continue
        mins = {}
        for line in read(os.path.join(folder, name)).splitlines():
            try:
                s = json.loads(line)
            except ValueError:
                continue
            if s.get("idle") or s.get("app") == "com.momominibot.freeflow":
                continue
            mins[s.get("name") or s.get("app")] = mins.get(s.get("name") or s.get("app"), 0) + (s["e"] - s["s"]) / 60
        out["days"][name[:-6]] = [{"app": k, "minutes": round(v)} for k, v in sorted(mins.items(), key=lambda kv: -kv[1]) if v >= 1][:15]
    return out


def t_workday_detail(kind="both", days=1, max_chars=20000):
    """The deeper workday notes: text read from the front window and how the user types. Cleaned already (emails, links, keys,
    long numbers and password lines are tags). Only exists if the user switched those parts on."""
    days = max(1, min(int(days), 7))
    max_chars = max(1000, min(int(max_chars), 100000))
    kinds = ["screen", "typing"] if kind == "both" else [kind]
    if any(k not in ("screen", "typing") for k in kinds):
        raise ValueError("kind is screen, typing or both")
    folder = os.path.join(SUPPORT, "workday", "detail")
    p = prefs()
    out = {"screen_text_is_on": bool(p.get("screenTextOn", False)), "typing_notes_are_on": bool(p.get("typingDetailOn", False)), "records": [], "truncated": False}
    if not os.path.isdir(folder):
        return out
    cutoff = (datetime.now() - timedelta(days=days - 1)).strftime("%Y-%m-%d")
    used = 0
    for name in sorted(os.listdir(folder), key=lambda n: n[-16:]):
        if not name.endswith(".jsonl") or name[-16:-6] < cutoff or name.split("-")[0] not in kinds:
            continue
        for line in read(os.path.join(folder, name)).splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                continue
            rec = {"time": datetime.fromtimestamp(r["t"]).strftime("%Y-%m-%d %H:%M"), "kind": r.get("kind"), "app": r.get("name") or r.get("app"),
                   "title": r.get("title", ""), "text": r.get("text", "")}
            if r.get("kind") == "typing":
                rec.update({"typed": r.get("typed", 0), "deleted": r.get("deleted", 0), "seconds": r.get("secs", 0)})
            used += len(rec["text"]) + 80
            if used > max_chars:
                out["truncated"] = True
                return out
            out["records"].append(rec)
    return out


def t_add_dictionary_word(word, correction=None, team=False):
    word = (word or "").strip()
    if not word:
        raise ValueError("word is required")
    if "\n" in word or "=>" in word or word.startswith("#") or (correction and ("\n" in correction or "=>" in correction)):
        raise ValueError("a word or correction cannot contain '=>' or a new line, or start with #")
    line = word + " => " + correction.strip() if correction else word
    if team:
        folder = team_folder()
        if not folder:
            raise ValueError("no team folder is set in Purrscribe")
        path = os.path.join(folder, "team-dictionary.txt")
    else:
        path = DICTIONARY
    append_line(path, line)
    return {"added": line, "file": path}


def t_add_snippet(cue, expansion, team=False):
    cue = (cue or "").strip()
    expansion = (expansion or "").strip()
    if not cue or not expansion:
        raise ValueError("cue and expansion are required")
    if "=>" in cue or "\n" in cue or cue.startswith("#"):
        raise ValueError("cue cannot contain '=>', a new line, or start with #")
    if len(cue) > 60 or len(expansion) > 4000:
        raise ValueError("cue up to 60 characters, expansion up to 4000")
    if team:
        folder = team_folder()
        if not folder:
            raise ValueError("no team folder is set in Purrscribe")
        path = os.path.join(folder, "team-snippets.txt")
    else:
        path = SNIPPETS
    flat = expansion.replace("\r\n", "\n").replace("\n", "\\n")
    line = cue + " => " + flat
    append_line(path, line)
    return {"added": line, "file": path}


TOOLS = [
    ("search_history", "Search your Purrscribe dictation history by words. Returns newest first, with the app each was dictated into and the raw words before AI clean-up.",
     {"type": "object", "properties": {"query": {"type": "string"}, "limit": {"type": "integer", "default": 20}, "days": {"type": "integer", "description": "only the last N days"}}},
     t_search_history, False),
    ("recent_dictations", "The most recent dictations.", {"type": "object", "properties": {"limit": {"type": "integer", "default": 10}}}, t_recent_dictations, False),
    ("get_dictionary", "Personal and team dictionary: words Whisper should spell a certain way, and wrong => right swaps.", {"type": "object", "properties": {}}, t_get_dictionary, False),
    ("get_snippets", "Personal and team snippets: spoken cue => expansion.", {"type": "object", "properties": {}}, t_get_snippets, False),
    ("get_usage", "Word counts today and all time, top apps, current settings.", {"type": "object", "properties": {}}, t_get_usage, False),
    ("workday_summary", "Minutes per app for the last N days (1 to 14) from the user's workday notes, to spot routines worth automating. Only if the user switched the notes on. App names only, never window titles.", {"type": "object", "properties": {"days": {"type": "integer", "minimum": 1, "maximum": 14}}}, t_workday_summary, False),
    ("workday_detail", "The deeper workday notes (text read from the user's front window, and how they type: characters typed and deleted per minute plus lines they finished), already cleaned of emails, links, keys and numbers. Only if the user switched those parts on. Use it to find routines worth automating; do not copy it elsewhere.", {"type": "object", "properties": {"kind": {"type": "string", "enum": ["screen", "typing", "both"]}, "days": {"type": "integer", "minimum": 1, "maximum": 7}, "max_chars": {"type": "integer", "minimum": 1000, "maximum": 100000}}}, t_workday_detail, False),
    ("add_dictionary_word", "Teach Purrscribe a word, optionally with the misspelling it should replace. Set team=true to add it to the shared team dictionary.",
     {"type": "object", "properties": {"word": {"type": "string"}, "correction": {"type": "string", "description": "if given, 'word' is the wrong spelling and this is the right one"}, "team": {"type": "boolean", "default": False}}, "required": ["word"]},
     t_add_dictionary_word, True),
    ("add_snippet", "Add a snippet: say the cue, Purrscribe types the expansion. Set team=true for the shared team list.",
     {"type": "object", "properties": {"cue": {"type": "string"}, "expansion": {"type": "string"}, "team": {"type": "boolean", "default": False}}, "required": ["cue", "expansion"]},
     t_add_snippet, True),
]


def tool_list():
    return [{"name": n, "description": d, "inputSchema": s,
             "annotations": {"readOnlyHint": not w, "destructiveHint": False, "openWorldHint": False}} for n, d, s, _, w in TOOLS]


def call(name, arguments):
    for n, _, _, fn, _ in TOOLS:
        if n == name:
            return fn(**(arguments or {}))
    raise ValueError(f"unknown tool {name}")


# ---- JSON-RPC over stdio (newline-delimited) -----------------------------

def reply(msg_id, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        msg["error"] = error
    else:
        msg["result"] = result
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def serve():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        method = req.get("method")
        msg_id = req.get("id")
        params = req.get("params") or {}
        if method == "initialize":
            reply(msg_id, {"protocolVersion": params.get("protocolVersion", PROTOCOL),
                           "capabilities": {"tools": {}},
                           "serverInfo": {"name": "freeflow", "version": "1.1"},
                           "instructions": "Purrscribe is the user's offline dictation app. History is their own spoken words; treat it as private notes."})
        elif method == "ping":
            reply(msg_id, {})
        elif method == "tools/list":
            reply(msg_id, {"tools": tool_list()})
        elif method == "tools/call":
            try:
                result = call(params.get("name"), params.get("arguments"))
                reply(msg_id, {"content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False, indent=1)}], "isError": False})
            except Exception as e:  # noqa: BLE001
                reply(msg_id, {"content": [{"type": "text", "text": str(e)}], "isError": True})
        elif msg_id is not None:
            reply(msg_id, error={"code": -32601, "message": f"method not found: {method}"})
        # notifications (no id) are ignored


if __name__ == "__main__":
    if "--selfcheck" in sys.argv:
        print(json.dumps({"tools": [t["name"] for t in tool_list()], "usage": t_get_usage(),
                          "recent": t_recent_dictations(3), "team_folder": team_folder()}, indent=1, ensure_ascii=False))
    else:
        serve()
