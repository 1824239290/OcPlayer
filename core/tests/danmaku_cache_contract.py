"""Cache persistence/lifetime through the exported ABI, with exact JSON IDs."""
import ctypes
import json
import os
import tempfile
import unittest
from pathlib import Path

class CacheContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffi=ctypes.CDLL(os.environ['OCP_CORE_LIBRARY_PATH'])
        cls.ffi.ocp_core_create.argtypes=[ctypes.c_char_p];cls.ffi.ocp_core_create.restype=ctypes.c_void_p
        cls.ffi.ocp_core_destroy.argtypes=[ctypes.c_void_p]
        cls.ffi.ocp_call.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p];cls.ffi.ocp_call.restype=ctypes.c_void_p
        cls.ffi.ocp_string_free.argtypes=[ctypes.c_void_p]
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='ocp-cache-');self.folder=Path(self.tmp.name);self.cores=[]
        self.core=self.open()
    def tearDown(self):
        for core in self.cores:self.ffi.ocp_core_destroy(core)
        self.tmp.cleanup()
    def call(self,method,core=None,**args):
        ptr=self.ffi.ocp_call(core or self.core,('danmakuCache.'+method).encode(),json.dumps(args).encode())
        self.assertTrue(ptr)
        try:return json.loads(ctypes.string_at(ptr))
        finally:self.ffi.ocp_string_free(ptr)
    def value(self,method,core=None,**args):
        r=self.call(method,core,**args);self.assertTrue(r['ok'],r);return json.loads(r['data']['payloadJSON'])
    def open(self,ttl=3600,capacity=2):
        core=self.ffi.ocp_core_create(b'{}');self.assertTrue(core);self.cores.append(core)
        r=self.call('open',core,directory=str(self.folder),commentsTTL=ttl,commentsMemoryCapacity=capacity)
        self.assertTrue(r['ok'],r);return core
    def match(self,id=9007199254740993):return {'episodeID':id,'shiftSeconds':4294967296,'animeID':9223372036854775807,'animeTitle':'作品','episodeTitle':'第1话'}
    def write_match(self,key='item',core=None,**args):return self.value('setEpisodeMatch',core,mediaID=key,payloadJSON=json.dumps(self.match()),**args)
    def comments(self,text='first'):return [{'cid':9223372036854775807,'p':'1,5,255,uid','m':text}]
    def write_comments(self,id=7,now=100,core=None,text='first'):return self.value('setComments',core,episodeID=id,now=now,payloadJSON=json.dumps(self.comments(text)))
    def test_exact_mapping_legacy_migration_revision_barrier(self):
        (self.folder/'mapping.json').write_text(json.dumps({'old':9223372036854775807}))
        self.assertEqual(self.value('episodeMatch',mediaID='old')['episodeID'],9223372036854775807)
        self.assertTrue(self.write_match(revision=18446744073709551615))
        self.assertFalse(self.write_match(revision=1))
        self.assertEqual(self.value('claimedRevision',mediaID='item'),18446744073709551615)
        reopened=self.open();self.assertEqual(self.value('episodeMatch',reopened,mediaID='item'),self.match())
        self.assertEqual(len(self.value('allEpisodeMatches',reopened)),2)
        self.assertFalse(self.value('removeEpisodeMatch',mediaID='item',revision=2))
        self.assertTrue(self.value('removeEpisodeMatch',mediaID='item'))
        self.assertIsNone(self.value('claimedRevision',mediaID='item'))
        self.assertIsNone(self.value('episodeMatch',mediaID='item'))
    def test_mapping_read_failure_never_overwrites_and_recovers(self):
        path=self.folder/'mapping.json';path.write_bytes(b'not-json')
        self.assertFalse(self.write_match())
        self.assertEqual(path.read_bytes(),b'not-json')
        path.write_text('{"old":42}')
        self.assertTrue(self.write_match())
        self.assertEqual(json.loads(path.read_text(encoding='utf-8'))['old']['episodeID'],42)
    def test_comments_reference_dates_lru_and_boundary_expiry(self):
        core=self.open(ttl=1,capacity=2)
        for id in [1,2]:self.write_comments(id,100,core,text=str(id))
        self.assertEqual(self.value('comments',core,episodeID=1,now=100.5),self.comments('1'))
        self.write_comments(3,100,core,text='3')
        for id in [1,2]:(self.folder/f'comments-{id}.json').unlink()
        self.assertIsNone(self.value('comments',core,episodeID=2,now=100.5))
        self.assertEqual(self.value('comments',core,episodeID=1,now=101),self.comments('1'))
        self.assertIsNone(self.value('comments',core,episodeID=1,now=101.0001))
        self.assertEqual(json.loads((self.folder/'comments-3.json').read_text(encoding='utf-8'))['fetchedAt'],100)
        self.assertEqual(self.value('memoryCount',core),1)
    def test_expired_memory_rereads_fresh_disk_and_purge_clears_every_layer(self):
        reader=self.open(ttl=1);writer=self.open(ttl=1)
        self.write_comments(core=reader,now=100)
        self.write_comments(core=writer,now=110,text='fresh')
        self.assertEqual(self.value('comments',reader,episodeID=7,now=110.5),self.comments('fresh'))
        self.assertTrue((self.folder/'comments-7.json').exists())
        self.write_match(core=reader,revision=3)
        self.value('setIntroHint',reader,episodeID=7,payloadJSON=json.dumps({'endSeconds':90,'evidenceCount':3}))
        self.assertTrue(self.value('purge',reader))
        self.assertEqual(self.value('memoryCount',reader),0)
        self.assertIsNone(self.value('claimedRevision',reader,mediaID='item'))
        self.assertIsNone(self.value('episodeMatch',reader,mediaID='item'))
        self.assertIsNone(self.value('introHint',reader,episodeID=7))
        self.assertEqual(list(self.folder.iterdir()),[])
    def test_intro_legacy_null_source_corruption_and_transient_recovery(self):
        path=self.folder/'intro-hints.json'
        path.write_text('{"7":{"endSeconds":90,"evidenceCount":3,"source":null}}')
        self.assertEqual(self.value('introHint',episodeID=7)['source'],'danmaku')
        core=self.open();path.write_bytes(b'bad')
        self.assertIsNone(self.value('introHint',core,episodeID=7))
        self.value('setIntroHint',core,episodeID=8,payloadJSON=json.dumps({'startSeconds':5,'endSeconds':100,'evidenceCount':4,'source':'learned'}))
        self.assertEqual(self.value('introHint',self.open(),episodeID=8)['source'],'learned')
        (self.folder/'comments-7.json').write_bytes(b'bad')
        self.assertIsNone(self.value('comments',episodeID=7,now=100))
        self.write_comments();self.assertEqual(self.value('comments',episodeID=7,now=100),self.comments())
    def test_zero_capacity_failed_disk_write_memory_and_invalid_arguments(self):
        core=self.open(capacity=0);self.write_comments(core=core)
        self.assertEqual(self.value('memoryCount',core),0)
        self.assertEqual(self.value('comments',core,episodeID=7,now=100),self.comments())
        # A directory at the destination causes atomic replacement to fail.
        (self.folder/'comments-8.json').mkdir()
        self.write_comments(8,core=self.core)
        self.assertEqual(self.value('comments',episodeID=8,now=100),self.comments())
        self.assertEqual(self.value('stats')['writeFailures'],1)
        self.assertFalse(any(p.name.startswith('.ocp-cache-') for p in self.folder.iterdir()))
        for method,args in [('open',{'directory':'relative'}),('open',{'directory':str(self.folder),'commentsMemoryCapacity':-1}),('comments',{'episodeID':1.5}),('claimRevision',{'mediaID':'x','revision':-1}),('setComments',{'episodeID':7,'payloadJSON':'bad'})]:
            self.assertEqual(self.call(method,**args)['code'],1002)

if __name__=='__main__':unittest.main(verbosity=2)
