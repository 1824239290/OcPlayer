"""Real HTTP nullable media DTOs exercised through the public Core C ABI."""
import subprocess
import sys
import unittest
from pathlib import Path
import bangumi_account_contract as fixture
import network_contract as network


class MediaNullableContract(unittest.TestCase):
    setUpClass = classmethod(fixture.AccountContract.setUpClass.__func__)
    call = network.NetworkContract.call
    success = network.NetworkContract.success

    def setUp(self):
        fixture.AccountContract.setUp(self)
        self.server = subprocess.Popen([sys.executable, '-u', str(Path(__file__).with_name('media_nullable_server.py'))],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.port = int(self.server.stdout.readline())

    def tearDown(self):
        self.server.terminate(); self.server.wait(timeout=10); self.server.stdout.close()
        fixture.AccountContract.tearDown(self)

    def profile(self, case, kind):
        return dict(id='fixture', kind=kind, baseURL=f'http://127.0.0.1:{self.port}/case/{case}',
            userID='user', accessToken='fixture-token', deviceID='fixture')

    def test_nullable_playback_sources_and_streams_keep_context(self):
        for kind in ('jellyfin', 'emby'):
            for case in ('null_streams', 'no_streams', 'empty_streams', 'null_sources', 'missing_sources'):
                with self.subTest(kind=kind, case=case):
                    info = self.success('playback.info', profile=self.profile(case, kind), itemId='item')
                    self.assertEqual(info['playSessionId'], 'session')
                    if case.endswith('sources'): self.assertEqual(info['mediaSources'], [])
                    else:
                        source = info['mediaSources'][0]
                        self.assertEqual(source['id'], 'source'); self.assertEqual(source['size'], 2**63-1)
                        self.assertEqual(source['runTimeSeconds'], 7200.25); self.assertEqual(source['mediaStreams'], [])

    def test_missing_null_empty_query_containers_are_empty_across_endpoints(self):
        commands = [('server.libraries', {}), ('browse.latest', {}), ('browse.resume', {}), ('browse.nextUp', {}),
            ('browse.random', {}), ('browse.library', {}), ('browse.played', {}), ('browse.seasons', {'seriesId':'series'}),
            ('browse.episodes', {'seriesId':'series'}), ('browse.similar', {'itemId':'item'}),
            ('browse.chapters', {'itemId':'item'}), ('media.segments', {'itemId':'item'}), ('media.subtitles', {'itemId':'item'}), ('media.fileInfo', {'itemId':'item'})]
        for kind in ('jellyfin', 'emby'):
            for case in ('containers_missing', 'containers_null', 'containers_empty'):
                for command, args in commands:
                    with self.subTest(kind=kind, case=case, command=command):
                        result = self.success(command, profile=self.profile(case, kind), **args)
                        items = result if isinstance(result, list) else result.get('items', result.get('Items', result.get('chapters')))
                        self.assertEqual(items, [], result)

    def test_canonical_item_and_similar_keep_images_identity_season_and_providers(self):
        for kind in ('jellyfin', 'emby'):
            for case in ('full_movie', 'full_episode', 'full_season'):
                args = dict(profile=self.profile(case, kind), itemId='item')
                item = self.success('browse.detail', **args)
                self.assertEqual(self.success('browse.similar', **args)['items'], [item])
                self.assertEqual(item['malID'], '456'); self.assertEqual(item['tmdbID'], '123'); self.assertEqual(item['anilistID'], '789')
                self.assertEqual(item['backdropImageTag'], 'backdrop'); self.assertEqual(item['parentBackdropImageTag'], 'parent-backdrop')
                self.assertEqual(item['logoImageTag'], 'parent-logo'); self.assertEqual(item['parentLogoItemID'], 'logo-parent')
                self.assertEqual(item['parentPrimaryImageItemID'], 'primary-parent'); self.assertEqual(item['parentPrimaryImageTag'], 'parent-primary')
                self.assertEqual(item['primaryImageTag'], None if case=='full_episode' else 'album-primary')
                if case=='full_season':
                    self.assertEqual(item['seasonID'], 'item'); self.assertEqual(item['seasonName'], '原生片名')
                    self.assertEqual(item['seasonNumber'], 3); self.assertIsNone(item['episodeNumber'])
            if kind=='emby':
                for case in ('emby_markers','emby_marker_fallback'):
                    segments=self.success('media.segments', profile=self.profile(case,kind), itemId='item')['items']
                    self.assertEqual([v['Id'] for v in segments], ['emby-intro-item','emby-credits-item'])
                    self.assertEqual(segments[0]['StartTicks'], 100000000); self.assertEqual(segments[0]['EndTicks'], 200000000)
                    self.assertEqual(segments[1]['EndTicks'], 72002500000)
                self.assertEqual(self.success('media.segments', profile=self.profile('emby_marker_unknown',kind), itemId='item')['items'], [])
            item = self.success('browse.detail', profile=self.profile('missing_identity',kind), itemId='item')
            self.assertTrue(item['id'].startswith('missing-')); self.assertEqual(item['name'], '未命名')
            self.assertEqual(item['genres'], []); self.assertEqual(item['cast'], [])
            self.assertFalse(item['playState']['played']); self.assertEqual(item['playState']['positionSeconds'], 0)

    def test_wrong_nonnull_types_are_decode_failures_and_not_empty_success(self):
        cases = [('wrong_chapters','browse.chapters'), ('wrong_list','browse.similar'), ('wrong_list','media.segments'), ('wrong_list','media.subtitles'),
            ('wrong_list','media.fileInfo'), ('wrong_genres','browse.detail'), ('wrong_people','browse.detail'),
            ('wrong_images','browse.detail'), ('wrong_ticks','browse.detail'), ('wrong_sources','playback.info'),
            ('wrong_streams','playback.info')]
        for kind in ('jellyfin', 'emby'):
            for case, command in cases:
                if kind=='emby' and command=='media.segments': continue
                result = self.call(command, profile=self.profile(case,kind), itemId='item')
                self.assertFalse(result['ok'], result)
                self.assertEqual(result['code'], 1514, result)
                self.assertFalse(result['retryable'], result)


if __name__ == '__main__': unittest.main(verbosity=2)
