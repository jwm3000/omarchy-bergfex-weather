#!/usr/bin/env python3
"""Bergfex public website adapter. Python standard library + curl only."""
import datetime as dt
import hashlib
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from urllib.parse import urljoin, urlsplit, urlencode

BASE = "https://www.bergfex.at"
STATE = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "omarchy/bergfex-weather/location.json"
CACHE = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "omarchy/bergfex-weather"


class Node:
    def __init__(self, tag="", attrs=()):
        self.tag, self.attrs, self.children = tag, dict(attrs), []

    def text(self):
        return " ".join(" ".join(c.text() if isinstance(c, Node) else c for c in self.children).split())

    def find(self, cls=None, tag=None):
        found = []
        for child in self.children:
            if isinstance(child, Node):
                if (cls is None or cls in child.attrs.get("class", "").split()) and (tag is None or tag == child.tag):
                    found.append(child)
                found.extend(child.find(cls, tag))
        return found

    def one(self, cls=None, tag=None):
        return next(iter(self.find(cls, tag)), Node())


class Tree(HTMLParser):
    def __init__(self, html):
        super().__init__(convert_charrefs=True)
        self.root = Node()
        self.stack = [self.root]
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        node = Node(tag, attrs)
        self.stack[-1].children.append(node)
        if tag not in {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                break

    def handle_data(self, data):
        self.stack[-1].children.append(data)


def weather_url(value):
    url = urlsplit(urljoin(BASE, value))
    if url.scheme != "https" or url.hostname != "www.bergfex.at" or url.port not in (None, 443) or url.username or url.password:
        raise ValueError("Bitte eine Bergfex.at-Wetteradresse verwenden.")
    if not url.path.endswith("/wetter/") or any(p in {".", ".."} for p in url.path.split("/")):
        raise ValueError("Bitte die Bergfex-Ortsseite mit /wetter/ am Ende wählen.")
    return BASE + url.path


def fetch(url):
    result = subprocess.run(["curl", "--fail", "--silent", "--show-error", "--compressed", "--proto", "=https", "--connect-timeout", "8", "--max-time", "25", url], capture_output=True, timeout=30)
    if result.returncode:
        raise ValueError("Bergfex ist gerade nicht erreichbar. Bitte erneut versuchen.")
    return result.stdout.decode("utf-8")


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as file:
            json.dump(data, file, ensure_ascii=False)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def read_json(path, default=None):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def number(text):
    match = re.search(r"[-−]?\d+(?:[.,]\d+)?", text)
    return float(match[0].replace(",", ".").replace("−", "-")) if match else None


def icon(description, symbol="", night=False):
    text = description.lower()
    if "gewitter" in text: return ""
    if "schnee" in text or "schneefall" in text: return ""
    if "regen" in text or re.match(r"b\dr[1-9]", symbol): return ""
    if "nebel" in text: return ""
    if "wolkenlos" in text or symbol == "a": return "" if night else ""
    if "heiter" in text or symbol == "b": return "" if night else ""
    return ""


def parse_narrative(root):
    """Read today's regional report, stopping at the next heading."""
    nodes = root.find()
    for index, node in enumerate(nodes):
        if node.tag != "h2" or not re.search(r"\bHeute\s*,", node.text()):
            continue
        for following in nodes[index + 1:]:
            if following.tag in {"h1", "h2"}:
                break
            if "txt_markup" in following.attrs.get("class", "").split():
                paragraphs = following.find(tag="p")
                body = "\n\n".join(p.text() for p in paragraphs) if paragraphs else following.text()
                return {"title": node.text(), "text": body}
    return {"title": "", "text": ""}


def parse_weather(html, url):
    root = Tree(html).root
    current = root.one("forecast-current")
    temperature = number(current.one("temperature").text())
    if temperature is None:
        raise ValueError("Diese Bergfex-Seite enthält keine lesbaren Wetterdaten.")
    name = re.sub(r"^Wetter\s+", "", root.one(tag="h1").text()).strip()
    stamp = current.one("time").text()
    description = stamp.split(" - ", 1)[-1] if " - " in stamp else ""
    rain = re.search(r"Niederschlag:\s*(\d+)\s*%", current.text())
    hour_img = root.one("forecast1h").one(tag="img")
    days = []
    for node in root.one("forecast9d-container").find("day"):
        date = re.search(r"(\d{2})\.(\d{2})\.(\d{4})", node.attrs.get("title", ""))
        if not date: continue
        image = node.one(tag="img")
        symbol = Path(image.attrs.get("src", "")).stem
        days.append({"date": "-".join([date[3], date[2], date[1]]), "max": number(node.one("tmax").text()), "min": number(node.one("tmin").text()), "icon": icon(image.attrs.get("title", ""), symbol), "wind": node.one("ff").text(), "sun": node.one("sonne").text(), "rain": node.one("rrp").text()})
    if not name or len(days) < 2:
        raise ValueError("Das Bergfex-Seitenformat wird noch nicht unterstützt.")
    return {"name": name, "url": url, "temperature": temperature, "description": description, "time": stamp.split(" - ")[0], "rain": rain[1] + "%" if rain else "—", "icon": icon(description, night="/night/" in hour_img.attrs.get("src", "")), "days": days, "fetchedAt": int(time.time()), "source": "Bergfex", "narrative": parse_narrative(root)}


def parse_search(raw):
    result, seen = [], set()
    for row in json.loads(raw):
        links = Tree(row.get("links", "")).root.find(tag="a")
        candidates = [n.attrs.get("href", "") for n in links] + [row.get("link", "")]
        for candidate in candidates:
            try:
                url = weather_url(candidate)
            except ValueError:
                continue
            if url in seen: continue
            label = Tree(row.get("label", "")).root.text()
            name = row.get("name", "").strip()
            if not name: continue
            result.append({"name": name, "url": url, "description": label.removeprefix(name).strip()})
            seen.add(url)
            break
    return result[:8]


def forecast(url, force=False):
    url = weather_url(url)
    cache_file = CACHE / (hashlib.sha256(url.encode()).hexdigest() + ".json")
    cached = read_json(cache_file)
    if not force and cached and "narrative" in cached and 0 <= time.time() - cached.get("fetchedAt", 0) < 900:
        return cached
    try:
        report = parse_weather(fetch(url), url)
        atomic_json(cache_file, report)
        return report
    except (ValueError, OSError, subprocess.TimeoutExpired):
        if cached:
            return dict(cached, stale=True, warning="Abruf fehlgeschlagen – gespeicherte Wetterdaten.")
        raise


def main(args):
    action = args[0]
    if action == "search":
        query = args[1].strip()
        if query.startswith("https://"):
            url = weather_url(query)
            return {"results": [{"name": "Bergfex-Ort", "url": url, "description": urlsplit(url).path}]}
        return {"results": parse_search(fetch(BASE + "/api/web/search/global?" + urlencode({"type": "header", "q": query}))) if len(query) >= 3 else []}
    if action == "location":
        return read_json(STATE, {})
    if action == "select":
        url = weather_url(args[1])
        report = forecast(url)
        if report.get("stale"):
            raise ValueError("Standort konnte nicht geladen werden. Bitte erneut versuchen.")
        atomic_json(STATE, {"name": report["name"], "url": url})
        return {"report": report}
    if action == "weather":
        location = read_json(STATE, {})
        return {"report": forecast(location["url"], "--force" in args)} if location.get("url") else {"needsLocation": True}
    raise ValueError("Unbekannter Befehl")


if __name__ == "__main__":
    try:
        print(json.dumps(main(sys.argv[1:]), ensure_ascii=False))
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False))
        sys.exit(1)
