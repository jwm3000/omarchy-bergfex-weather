import gzip
import io
import os
from types import SimpleNamespace
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import bergfex as b

HTML = '''<h1>Wetter Testort</h1><div class="forecast-current">
<div class="time">Heute, 20:00 - leichter Schneefall</div>
<div>Niederschlag: 0%</div><div class="temperature">−2,5 °C</div></div>
<div class="forecast1h"><img src="/night/snow.png"></div>
<div class="forecast9d-container">
<div class="day" title="Wetterprognose 31.12.2026"><div class="tmax">0°C</div><div class="tmin">−4°C</div><div class="ff">NW 2</div></div>
<div class="day" title="Wetterprognose 01.01.2027"><div class="tmax">1°C</div><div class="tmin">−3°C</div></div></div>'''
URL = 'https://www.bergfex.at/sommer/testort/wetter/'


class AdapterTests(unittest.TestCase):
    def test_temperature_preference_defaults_and_persists(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(b, "PREFERENCES", Path(directory) / "preferences.json"):
            self.assertFalse(b.main(["preferences"])["showBarTemperature"])
            b.main(["set-bar-temperature", "true"])
            self.assertTrue(b.main(["preferences"])["showBarTemperature"])
            b.main(["set-bar-temperature", "false"])
            self.assertFalse(b.main(["preferences"])["showBarTemperature"])
            with self.assertRaises(ValueError): b.main(["set-bar-temperature", "invalid"])

    def test_regional_report_preserves_paragraphs(self):
        tree = b.Tree('<h2>Steiermark - Heute, <span>Donnerstag</span></h2><div class="txt_markup"><p>Erster Absatz.</p><p>Zweiter Absatz.</p></div><h2>Morgen</h2><div class="txt_markup">Anderer Bericht.</div>')
        self.assertEqual(b.parse_narrative(tree.root), {'title': 'Steiermark - Heute, Donnerstag', 'text': 'Erster Absatz.\n\nZweiter Absatz.'})

    def test_missing_report_does_not_use_tomorrow(self):
        tree = b.Tree('<h2>Heute, Donnerstag</h2><h2>Morgen</h2><div class="txt_markup">Morgenbericht.</div>')
        self.assertEqual(b.parse_narrative(tree.root), {'title': '', 'text': ''})

    def test_temperatures_dates_and_zero_rain(self):
        report = b.parse_weather(HTML, URL)
        self.assertEqual(report['temperature'], -2.5)
        self.assertEqual(report['rain'], '0%')
        self.assertEqual(report['days'][1]['date'], '2027-01-01')
        self.assertEqual(report['days'][0]['min'], -4)
        self.assertEqual(report['icon'], '')

    def test_invalid_page_is_not_weather(self):
        with self.assertRaises(ValueError):
            b.parse_weather('<h1>Bitte anmelden</h1>', URL)

    def test_search_filters_non_weather_and_deduplicates(self):
        raw = json.dumps([
            {'name': 'Ort', 'links': '<a href="/sommer/ort/wetter/">Wetter</a>'},
            {'name': 'Ort', 'link': '/sommer/ort/wetter/'},
            {'name': 'Tour', 'link': '/sommer/touren/123/'},
        ])
        self.assertEqual([r['name'] for r in b.parse_search(raw)], ['Ort'])

    def test_url_rejects_external_targets(self):
        for url in ['https://example.com/wetter/', 'http://www.bergfex.at/wetter/', 'https://www.bergfex.at@evil.test/wetter/', 'file:///wetter/']:
            with self.assertRaises(ValueError): b.weather_url(url)

    def test_cache_failure_and_location_isolation(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(b, 'CACHE', Path(directory)), patch.object(b, 'fetch', return_value=HTML) as fetch:
            first = b.forecast(URL)
            self.assertEqual(first, b.forecast(URL))
            self.assertEqual(fetch.call_count, 1)
            fetch.side_effect = ValueError('offline')
            self.assertTrue(b.forecast(URL, force=True)['stale'])
            with self.assertRaises(ValueError): b.forecast(URL.replace('testort', 'anderer-ort'))

    def test_failed_selection_preserves_location(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(b, 'STATE', Path(directory) / 'location.json'), patch.object(b, 'forecast', side_effect=ValueError('offline')):
            b.atomic_json(b.STATE, {'name': 'Bisheriger Ort', 'url': URL})
            with self.assertRaises(ValueError): b.main(['select', URL])
            self.assertEqual(b.read_json(b.STATE)['name'], 'Bisheriger Ort')


class Response(io.BytesIO):
    def __init__(self, data, **headers):
        super().__init__(data)
        self.headers = headers
        self.read_sizes = []

    def read1(self, size):
        self.read_sizes.append(size)
        return super().read1(size)


class ResourceLimitTests(unittest.TestCase):
    def test_identity_and_gzip(self):
        self.assertEqual(b.read_response(Response(b"hello")), "hello")
        self.assertEqual(b.read_response(Response(gzip.compress(b"hello"), **{"Content-Encoding": "gzip"})), "hello")

    def test_wire_limit_without_length_and_with_false_length(self):
        for headers in ({}, {"Content-Length": "1"}):
            response = Response(b"x" * 101, **headers)
            with patch.object(b, "WIRE_LIMIT", 100), self.assertRaises(ValueError):
                b.read_response(response)
            self.assertLessEqual(response.tell(), 101)
            self.assertLessEqual(max(response.read_sizes), 101)

    def test_large_declared_length_never_reads(self):
        response = Response(b"x", **{"Content-Length": str(b.WIRE_LIMIT + 1)})
        with self.assertRaises(ValueError): b.read_response(response)
        self.assertEqual(response.read_sizes, [])

    def test_gzip_bomb_and_exact_boundary(self):
        with patch.object(b, "BODY_LIMIT", 100):
            self.assertEqual(b.read_response(Response(gzip.compress(b"x" * 100), **{"Content-Encoding": "gzip"})), "x" * 100)
            with self.assertRaises(ValueError):
                b.read_response(Response(gzip.compress(b"x" * 1000000), **{"Content-Encoding": "gzip"}))

    def test_compressed_wire_limit(self):
        response = Response(gzip.compress(os.urandom(200)), **{"Content-Encoding": "gzip"})
        with patch.object(b, "WIRE_LIMIT", 100), self.assertRaises(ValueError):
            b.read_response(response)

    def test_gzip_truncation_trailing_data_and_unsupported_encoding(self):
        for data, encoding in [(gzip.compress(b"hello")[:-2], "gzip"), (gzip.compress(b"hi") + gzip.compress(b"there"), "gzip"), (b"hello", "br")]:
            with self.assertRaises(ValueError):
                b.read_response(Response(data, **{"Content-Encoding": encoding}))

    def test_tree_complexity(self):
        with self.assertRaises(ValueError): b.Tree("<div>" * b.TREE_DEPTH)
        with patch.object(b, "TREE_NODES", 3), self.assertRaises(ValueError):
            b.Tree("<br>" * 4)

    def test_safe_file_reads(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "data.json"
            path.write_text('{"ok":true}')
            self.assertEqual(b.read_json(path), {"ok": True})
            self.assertIsNone(b.read_json(path, limit=2))
            link = Path(directory) / "link"
            link.symlink_to(path)
            self.assertIsNone(b.read_json(link))
            parent_link = Path(directory) / "parent"
            parent_link.symlink_to(directory, target_is_directory=True)
            self.assertIsNone(b.read_json(parent_link / "data.json"))
            fifo = Path(directory) / "fifo"
            os.mkfifo(fifo)
            self.assertIsNone(b.read_json(fifo))
            self.assertIsNone(b.read_json(Path(directory)))
            actual = os.stat(path)
            wrong_owner = SimpleNamespace(st_mode=actual.st_mode, st_uid=os.getuid() + 1, st_size=actual.st_size)
            with patch.object(b.os, "fstat", return_value=wrong_owner), patch.object(b.os, "read") as read:
                self.assertIsNone(b.read_json(path))
                read.assert_not_called()

    def test_growing_file_read_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "data.json"
            path.write_text('{}')
            with patch.object(b.os, "read", side_effect=lambda fd, count: b"x" * count) as read:
                self.assertIsNone(b.read_json(path, limit=100))
                self.assertEqual(sum(call.args[1] for call in read.call_args_list), 101)


if __name__ == '__main__': unittest.main()
