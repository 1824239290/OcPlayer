"""Canonical file/subtitle projections and raw compatibility through the C ABI."""
import subprocess
import unittest
import json
import struct
from pathlib import Path
from urllib.request import urlopen
import bangumi_account_contract as fixture
import network_contract as network


class MediaProjectionContract(unittest.TestCase):
    setUpClass = classmethod(fixture.AccountContract.setUpClass.__func__)
    call = network.NetworkContract.call
    success = network.NetworkContract.success

    def setUp(self):
        fixture.AccountContract.setUp(self)
        self.server = subprocess.Popen(['/usr/bin/python3','-u',str(Path(__file__).with_name('media_projection_server.py'))],
            stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
        self.port = int(self.server.stdout.readline())

    def tearDown(self):
        self.server.terminate();self.server.wait(timeout=10);self.server.stdout.close()
        fixture.AccountContract.tearDown(self)

    def profile(self,case='full',kind='jellyfin'):
        return dict(id='fixture',kind=kind,baseURL=f'http://127.0.0.1:{self.port}/case/{case}',userID='user',token='fixture-token')

    def metadata(self,case='full',kind='jellyfin',method='media.subtitles',**args):
        return self.success(method,profile=self.profile(case,kind),itemId='item',**args)

    def test_source_priority_explicit_missing_and_empty_ids_never_replay_fallback(self):
        for kind in ('jellyfin','emby'):
            self.assertEqual([v['index'] for v in self.metadata(kind=kind)['subtitles']],[3,6,7])
            self.assertEqual(self.metadata(kind=kind,mediaSourceId='stream')['subtitles'][0]['title'],'直推资源')
            self.assertEqual(self.metadata(kind=kind,mediaSourceId='other')['subtitles'][0]['title'],'另一资源')
            for source in ('missing',''):
                self.assertEqual(self.metadata(kind=kind,mediaSourceId=source)['subtitles'],[])
            self.assertEqual(self.metadata('stream_only',kind)['subtitles'][0]['mediaSourceId'],'stream')
            self.assertEqual(self.metadata('none_playable',kind)['subtitles'][0]['mediaSourceId'],'stream')
            self.assertEqual(self.metadata('empty',kind)['subtitles'],[])
            self.assertIsNone(self.metadata('empty',kind)['fileInfo'])
            self.assertIsNone(self.metadata('missing_ids',kind)['subtitles'][0]['mediaSourceId'])

    def test_complete_file_projection_keeps_original_payloads_and_exact_int64(self):
        for kind in ('jellyfin','emby'):
            reply=self.metadata(kind=kind,method='media.fileInfo');info=reply['fileInfo']
            self.assertEqual(reply['PluginEnvelope'],{'unknown':[1,2,3]})
            self.assertEqual(reply['Items'][0]['PluginField'],'preserved')
            self.assertEqual(reply['Items'][0]['MediaSources'][1]['PluginData'],{'keep':'unknown'})
            self.assertEqual(info['sizeBytes'],2**63-1);self.assertEqual(info['durationSeconds'],7200.25)
            self.assertEqual(info['fileName'],'剧名 第1集.mkv');self.assertEqual(info['sourceCount'],3)
            video=info['video'];self.assertEqual(video['frameRate'],struct.unpack('f',struct.pack('f',23.976))[0] if kind=='jellyfin' else 23.976);self.assertEqual(video['videoRangeType'],'DOVIWithHDR10')
            self.assertEqual((video['width'],video['height'],video['bitDepth']),(3840,2160,10))
            self.assertEqual(info['audioTracks'][0]['sampleRate'],48000);self.assertIsNone(info['audioTracks'][1]['title'])
            self.assertEqual(len(info['subtitleTracks']),7);self.assertIsNone(info['subtitleTracks'][0]['title'])
            self.assertEqual([v['codec'] for v in reply['subtitles']],['ass','webvtt','ssa'])
            self.assertEqual(reply['subtitles'][0]['title'],'简中外挂')

    def test_frame_rate_bounds_nullable_fields_and_titles_match_native_rules(self):
        for kind in ('jellyfin','emby'):
            for case,expected in [('fps_zero',29.97),('fps_high',25),('fps_negative',24),('fps_invalid',None),('fps_missing',60),('fps_round',25 if kind=='jellyfin' else 999.99999)]:
                if kind=='jellyfin' and expected is not None:expected=struct.unpack('f',struct.pack('f',expected))[0]
                self.assertEqual(self.metadata(case,kind)['fileInfo']['video']['frameRate'],expected)
            for case,expected in [('path_root','/'),('path_trailing','folder'),('path_empty',None),('path_windows','C:\\folder\\file.mkv')]:
                self.assertEqual(self.metadata(case,kind)['fileInfo']['fileName'],expected)
            info=self.metadata('null_fields',kind)['fileInfo']
            for key in ('container','sizeBytes','durationSeconds','fileName'):self.assertIsNone(info[key])
            self.assertFalse(info['video']['isInterlaced']);self.assertFalse(info['audioTracks'][0]['isDefault'])

    def test_malformed_nonnull_scalars_are_nonretryable_decode_errors(self):
        for kind in ('jellyfin','emby'):
            for case in ('wrong_size','wrong_ticks','wrong_supports','wrong_width','wrong_rate','wrong_sample','wrong_flag'):
                for method in ('media.subtitles','media.fileInfo'):
                    reply=self.call(method,profile=self.profile(case,kind),itemId='item')
                    self.assertFalse(reply['ok'],reply);self.assertEqual(reply['code'],1514,reply);self.assertFalse(reply['retryable'])

    def test_enum_tolerance_tracks_the_actual_server_flavor(self):
        for case in ('unknown_stream','lower_stream','unknown_range','fps_overflow','fps_small'):
            reply=self.call('media.fileInfo',profile=self.profile(case,'jellyfin'),itemId='item')
            self.assertFalse(reply['ok'],reply);self.assertEqual(reply['code'],1514)
            emby=self.metadata(case,'emby')
            self.assertEqual(len(emby['subtitles']),3)
            if case=='unknown_range':self.assertEqual(emby['fileInfo']['video']['videoRangeType'],'FutureHDR')

    def test_requests_arguments_and_read_only_metadata_boundary(self):
        for kind in ('jellyfin','emby'):
            self.metadata(kind=kind,mediaSourceId='play')
            self.metadata(kind=kind,mediaSourceId=None)
            self.metadata(kind=kind,method='media.fileInfo')
            for invalid in (True,1,{},[]):
                reply=self.call('media.subtitles',profile=self.profile(kind=kind),itemId='item',mediaSourceId=invalid)
                self.assertFalse(reply['ok']);self.assertEqual(reply['code'],1002)
        with urlopen(f'http://127.0.0.1:{self.port}/stats') as response:rows=json.load(response)
        self.assertEqual(len(rows),6)
        for row in rows:
            self.assertEqual(row['method'],'GET');self.assertTrue(row['path'].endswith('/Items'))
            self.assertEqual(row['query'],{'ids':['item'],'fields':['MediaSources'],'userId':['user']})


if __name__=='__main__':unittest.main(verbosity=2)
