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


if __name__ == '__main__': unittest.main()
