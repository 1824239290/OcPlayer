"""TMDB response fidelity and signed request ranges through the real C ABI."""
import json
import pathlib
import subprocess
import sys
import urllib.request
from network_contract import NetworkContract

MAX = 9223372036854775807
MIN = -9223372036854775808

class TmdbWireContract(NetworkContract):
    def setUp(self):
        self.process = subprocess.Popen([sys.executable, '-u', str(pathlib.Path(__file__).with_name('tmdb_wire_server.py'))],
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.base = 'http://127.0.0.1:' + self.process.stdout.readline().strip()
        self.core = self.ffi.ocp_core_create(b'{}')
        self.assertTrue(self.core)

    def tearDown(self):
        self.ffi.ocp_core_destroy(self.core)
        self.process.terminate()
        self.process.wait(timeout=5)
        self.process.stdout.close()

    def tmdb(self, method, scenario='exact', **args):
        return self.success('tmdb.' + method, apiKey='fixture', apiBase=self.base + '/' + scenario, **args)

    def records(self):
        with urllib.request.urlopen(self.base + '/stats', timeout=5) as response:
            return json.load(response)

    def test_exact_nested_integer_and_optional_model_fields(self):
        entity = self.tmdb('entity', id=MAX, mediaType='movie')
        self.assertEqual(entity['id'], MAX)
        self.assertEqual(entity['cast'][0]['id'], MAX-1)
        self.assertEqual(entity['seasons'][0]['season_number'], MAX-2)
        self.assertEqual(entity['seasons'][0]['episode_count'], MAX-3)
        self.assertEqual(entity['collection_id'], MAX-4)
        self.assertEqual(entity['overview'], '完整简介😀')
        self.assertEqual(entity['content_rating'], 'PG')
        self.assertEqual(entity['imdb_id'], 'tt123')
        season = self.tmdb('season', id=MAX, seasonNumber=MAX)
        self.assertEqual(season['season_number'], MAX-2)
        self.assertEqual(season['episodes'][0]['id'], MAX-3)
        self.assertEqual(season['episodes'][0]['episode_number'], MAX-4)
        self.assertEqual(season['episodes'][0]['runtime'], MAX-5)
        self.assertEqual([r['id'] for r in self.tmdb('search', query='作品', year=MAX)], [MAX, MAX-1])

    def test_foundation_numeric_and_array_projection(self):
        entity = self.tmdb('entity', 'numeric', id=1)
        self.assertEqual(entity['id'], 7)
        self.assertEqual(entity['vote_average'], 1)
        self.assertEqual(entity['collection_id'], 8)
        self.assertEqual([r['id'] for r in entity['cast']], [1,-7])
        self.assertEqual(entity['seasons'][0]['season_number'], 3)
        self.assertEqual(entity['seasons'][0]['episode_count'], 19)
        season = self.tmdb('season', 'numeric', id=1, seasonNumber=2)
        self.assertEqual([r['episode_number'] for r in season['episodes']], [-2,0])
        self.assertEqual(season['episodes'][0]['runtime'], 4)
        self.assertEqual([r['id'] for r in self.tmdb('search', 'numeric', query='作品')], [1,7])
        entity = self.tmdb('entity', 'mixed', id=1)
        for field in ('cast', 'genres', 'seasons'): self.assertEqual(entity[field], [])
        self.assertEqual(self.tmdb('search', 'mixed', query='作品'), [])
        self.assertEqual(self.tmdb('season', 'mixed', id=1, seasonNumber=1)['episodes'], [])
        self.assertEqual(len(self.tmdb('entity', 'prefix', id=1)['cast']), 18)
        self.assertEqual(self.tmdb('entity', 'preferred', id=1)['content_rating'], '12')
        entity = self.tmdb('entity', 'overflow', id=1)
        self.assertIsNone(entity['vote_average'])
        self.assertIsNone(self.tmdb('search', 'overflow', query='作品')[0]['popularity'])

    def test_native_wire_encodings_preserve_unicode_and_integer_ids(self):
        for scenario in ('utf8bom','utf16le','utf16be','utf16lebom','utf16bebom','utf32le','utf32be','utf32bebom'):
            with self.subTest(scenario=scenario):
                entity = self.tmdb('entity', scenario, id=MAX)
                self.assertEqual(entity['id'], MAX)
                self.assertEqual(entity['overview'], '完整简介😀')

    def test_malformed_wire_returns_decoding_error(self):
        for scenario in ('invalid','array','utf32lebom'):
            result = self.call('tmdb.entity', apiKey='fixture', apiBase=self.base+'/'+scenario, id=1)
            self.assertFalse(result['ok'], result)
            self.assertEqual(result['code'], 1514)
            self.assertFalse(result['retryable'])

    def test_signed_ranges_and_invalid_argument_preflight(self):
        self.tmdb('entity', id=MIN)
        self.tmdb('season', id=-1, seasonNumber=MIN)
        self.tmdb('search', query='作品', year=MAX, mediaType='movie')
        self.tmdb('search', query='作品', year=MIN, mediaType='tv')
        records = self.records()
        self.assertEqual(records[0]['path'], '/exact/movie/'+str(MIN))
        self.assertEqual(records[1]['path'], '/exact/tv/-1/season/'+str(MIN))
        self.assertEqual(records[2]['query']['year'], [str(MAX)])
        self.assertEqual(records[3]['query']['first_air_date_year'], [str(MIN)])
        for method, args in [('entity',dict(id=MAX+1)),('entity',dict(id=True)),
                             ('season',dict(id=1,seasonNumber=MAX+1)),('season',dict(id=1,seasonNumber=1.5)),
                             ('search',dict(query='作品',year=MAX+1)),('search',dict(query='作品',year=True))]:
            result = self.call('tmdb.'+method, apiKey='fixture', apiBase=self.base+'/exact', **args)
            self.assertEqual(result['code'], 1002, result)
        self.assertEqual(self.records(), records)

for name in list(vars(NetworkContract)):
    if name.startswith('test_'): setattr(TmdbWireContract, name, None)
del NetworkContract
if __name__ == '__main__':
    import unittest
    unittest.main(verbosity=2)
