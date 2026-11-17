"""Portable native-format settings backup policy through the public ABI."""
import base64
import json
import unittest
import bangumi_account_contract as fixture
import network_contract as network

TMDB=dict(language='zh-CN',preferText=True,replaceImages=False,showPlaceholders=True,cacheDays=30)
PLAYBACK=dict(skipIntro=True,skipOutro=True,outroRetentionSeconds=10,subtitleLanguage='zh-Hans',lumaUpscaler='off',httpReadAheadMiB=0,httpBackBufferMiB=0)
DANMAKU=dict(danmakuEnabled=True,opacity=.85,displayArea=.75,blockTop=False,blockBottom=False,blockScroll=False,fontSize=22,autoLoad=True)
GENERAL=dict(bangumiEnabled=True,moviepilotEnabled=True,episodeSortAscending=True)
def backup(**modules):return dict(formatVersion=1,exportedAt='2026-11-14T00:00:00Z',appVersion='fixture',**modules)

class SettingsBackupContract(unittest.TestCase):
    setUpClass=classmethod(fixture.AccountContract.setUpClass.__func__)
    setUp=fixture.AccountContract.setUp
    tearDown=fixture.AccountContract.tearDown
    call=network.NetworkContract.call
    success=network.NetworkContract.success
    def project(self,value,method='decode',encoding='utf-8'):
        raw=value if isinstance(value,str) else json.dumps(value,ensure_ascii=False)
        return self.success('settings.backup.'+method,inputBase64=base64.b64encode(raw.encode(encoding)).decode())
    def test_partial_modules_legacy_mirror_and_unknown_fields(self):
        result=self.project(backup(mirror=dict(enabled=True,tmdbEnabled=False),future=dict(token='ignored')))
        value=json.loads(result['backupJSON']);self.assertNotIn('future',value);self.assertEqual(value['mirror'],dict(bangumiEnabled=True,tmdbEnabled=False))
        self.assertTrue(result['summary']['hasMirror']);self.assertFalse(result['summary']['hasPlayback']);self.assertFalse(result['summary']['hasTMDb'])
        self.assertEqual([e['operation'] for e in result['effects']],['set','remove','set','remove','remove'])
    def test_integer_precision_float_spellings_and_first_duplicate_key(self):
        raw=json.dumps(backup(playback=dict(PLAYBACK,subtitleMarginVertical=9007199254740993))).replace('9007199254740993','9007199254740993.0')
        result=self.project(raw);self.assertEqual(json.loads(result['backupJSON'])['playback']['subtitleMarginVertical'],9007199254740993)
        raw=raw.replace('"formatVersion": 1','"formatVersion": 1, "formatVersion": 2')
        self.assertEqual(json.loads(self.project(raw)['backupJSON'])['formatVersion'],1)
        result=self.project(backup(playback=dict(PLAYBACK,subtitleMarginVertical=9223372036854775807)))
        effect=next(e for e in result['effects'] if e['field']=='playback.subtitleMarginVertical')
        self.assertEqual(effect['valueJSON'],'9223372036854775807')
    def test_schema_rejects_missing_malformed_and_out_of_range_scalars(self):
        cases=[backup(tmdb={}),backup(playback=dict(PLAYBACK,skipIntro=1)),backup(playback=dict(PLAYBACK,subtitlePrimaryColor=4294967296)),backup(playback=dict(PLAYBACK,subtitlePrimaryColor=-1)),backup(mirror=dict(enabled='yes',bangumiEnabled=True)),backup(danmaku=dict(DANMAKU,opacity='0.85'))]
        for value in cases:
            reply=self.call('settings.backup.decode',inputBase64=base64.b64encode(json.dumps(value).encode()).decode());self.assertEqual(reply['code'],2702,reply);self.assertFalse(reply['retryable'])
    def test_version_gate_and_empty_error_preserve_encoder_compatibility(self):
        for version in (0,-1):self.project(dict(backup(),formatVersion=version))
        newer=dict(backup(),formatVersion=2)
        self.assertEqual(json.loads(self.project(newer,'prepare')['backupJSON'])['formatVersion'],2)
        reply=self.call('settings.backup.decode',inputBase64=base64.b64encode(json.dumps(newer).encode()).decode());self.assertEqual(reply['code'],2703);self.assertEqual(reply['data']['version'],2)
        self.assertEqual(self.call('settings.backup.decode',inputBase64='')['code'],2701)
    def test_utf16_utf32_and_foundation_date_forms(self):
        for encoding in ('utf-8-sig','utf-16','utf-16-le','utf-16-be','utf-32','utf-32-le','utf-32-be'):
            self.assertEqual(json.loads(self.project(backup(),encoding=encoding)['backupJSON'])['appVersion'],'fixture')
        for stamp in ('2026-02-30T00:00:00Z','2026-01-01T25:61:61Z','2026-1-1T0:0:0Z','2026-01-01T00:00:00.123Z','2026-01-01T00:00:00+0800','2026-01-01T00:00:00Zextra'):
            self.project(dict(backup(),exportedAt=stamp))
    def test_restore_is_ordered_and_preserves_nullable_and_empty_credentials(self):
        value=backup(tmdb=dict(TMDB,apiKey=''),playback=dict(PLAYBACK,subtitleLanguage='invalid',lumaUpscaler='invalid',subtitleBold=False,subtitlePrimaryColor=0),danmaku=dict(DANMAKU,dandanplayGatewayURL=''),general=dict(GENERAL,homeSections=''),mirror=dict(bangumiRootDomain='\u200b \n',tmdbAPIBaseURL=' raw '))
        result=self.project(value);effects=result['effects'];names=[e['field'] for e in effects]
        for name in ('tmdb.apiKey','playback.subtitleLanguage','playback.lumaUpscaler','danmaku.dandanplayGatewayURL','general.homeSections'):self.assertNotIn(name,names)
        self.assertLess(names.index('playback.httpBackBufferMiB'),names.index('playback.subtitleBold'))
        domain=next(e for e in effects if e['field']=='mirror.bangumiRootDomain');self.assertEqual(domain['operation'],'remove')
        api=next(e for e in effects if e['field']=='mirror.tmdbAPIBaseURL');self.assertEqual(json.loads(api['valueJSON']),' raw ')
    def test_snapshot_getter_facts_defaults_enum_and_color_policy(self):
        fact=lambda value:dict(present=True,value=value)
        result=self.success('settings.backup.snapshot',preferences={'playback.outroRetentionSeconds':fact(0),'playback.subtitleLanguage':fact('bad'),'playback.subtitlePrimaryColor':fact(0),'playback.subtitleBold':fact(False),'mirror.bangumiRootDomain':fact('\u200b example.test \u200b')},tmdb=TMDB,exportedAt='2026-11-14T00:00:00Z',appVersion='fixture',deviceName=None,dandanplayGatewayURL='')
        value=json.loads(result['backupJSON']);self.assertEqual(value['playback']['outroRetentionSeconds'],0);self.assertEqual(value['playback']['subtitleLanguage'],'zh-Hans');self.assertNotIn('subtitlePrimaryColor',value['playback']);self.assertFalse(value['playback']['subtitleBold']);self.assertEqual(value['mirror']['bangumiRootDomain'],'example.test');self.assertEqual(value['danmaku']['fontSize'],22)
    def test_unicode_grapheme_secret_summary_and_null_modules(self):
        key='prefix-a👩‍👩‍👧‍👦🇨🇳e\u0301z'
        result=self.project(backup(tmdb=dict(TMDB,apiKey=key),playback=None,mirror=None))
        self.assertEqual(result['summary']['tmdbKeyTail'],'••••👩‍👩‍👧‍👦🇨🇳e\u0301z');self.assertFalse(result['summary']['hasPlayback']);self.assertFalse(result['summary']['hasMirror'])
    def test_legacy_core_configuration_and_diagnostic_aliases_are_unchanged(self):
        self.assertEqual(self.success('config.export')['schemaVersion'],1)
        self.assertEqual(self.success('diag.export',includeConfig=False)['config'],None)
        self.assertEqual(self.success('settings.backup.capabilities')['formatVersion'],1)

if __name__=='__main__':unittest.main()
