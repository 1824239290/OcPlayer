"""Actual C ABI repository ownership/projections and disposable-cache recovery."""
import concurrent.futures
import json
import pathlib
import tempfile
from network_contract import NetworkContract

class MediaRepositoryContract(NetworkContract):
    def repo(self, command, **args):
        return self.success('mediaRepository.' + command, **args)
    def test_all_memory_buckets_keep_exact_payloads_and_touch_lru(self):
        self.repo('open', itemLimit=2, detailLimit=2, episodeListLimit=2, pageLimit=2)
        for bucket in ('items', 'details', 'episodes', 'pages', 'home'):
            def put(key, entry): return self.repo('put', bucket=bucket, payloadJSON=json.dumps(dict(key=key, entry=entry)))
            def get(key): return self.repo('get', bucket=bucket, payloadJSON=json.dumps(dict(key=key)))
            payload=dict(id=9223372036854775807, episodes=[dict(episodeNumber=-9223372036854775808)], extra='retained')
            put('a', dict(value=payload, fetchedAt=0.125)); put('b', dict(value='b', fetchedAt=1))
            if bucket == 'home':
                self.assertIsNone(get('a')); self.assertEqual(get('b')['value'], 'b')
            else:
                self.assertEqual(get('a')['value'], payload)
                before=self.repo('stats'); self.repo('all', bucket=bucket); self.assertEqual(self.repo('stats'), before)
                put('c', dict(value='c', fetchedAt=2)); self.assertIsNone(get('b'))
            put('a', None); self.assertIsNone(get('a'))
            self.repo('clearBucket',bucket=bucket)
            put('é',dict(value='first',fetchedAt=1)); put('e\u0301',dict(value='updated',fetchedAt=2))
            self.assertEqual(get('é')['value'],'updated')
            all_values=self.repo('all',bucket=bucket); self.assertEqual(len(all_values),1)
            self.assertEqual(all_values[0]['key'],'é')
        self.repo('clear')
        self.assertTrue(all(b['count']==0 for b in self.repo('stats')['buckets'].values()))
        self.assertEqual(self.server.records, [])

    def test_concurrent_claims_keep_one_owner_through_memory_invalidation(self):
        args=dict(kind='page', key=dict(parentID='library', searchTerm='猫', startIndex=0, limit=20))
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            claims=list(pool.map(lambda _:self.repo('claim', **args),range(32)))
        self.assertEqual(sum(c['owner'] for c in claims), 1)
        self.assertEqual(len({c['ticket'] for c in claims}), 1)
        self.repo('clear')
        self.assertFalse(self.repo('claim', **args)['owner'])
        self.repo('finish', ticket=claims[0]['ticket'])
        self.assertEqual(self.repo('stats')['flights'], 0)
        next_claim=self.repo('claim', **args)
        self.assertTrue(next_claim['owner']); self.assertNotEqual(next_claim['ticket'], claims[0]['ticket'])

    def test_preflight_errors_do_not_drop_existing_entries_or_ownership(self):
        self.repo('open', itemLimit=0)
        self.repo('put', bucket='items', payloadJSON=json.dumps(dict(key=dict(seriesID='a', seasonID='b'),entry=dict(value='retained', fetchedAt=1))))
        before=self.repo('stats')
        for args in [dict(bucket='unknown',payloadJSON='{}'),dict(bucket='items',payloadJSON='invalid'),dict(bucket='items',payloadJSON='{"key":"x","entry":{}}')]:
            result=self.call('mediaRepository.put', **args); self.assertFalse(result['ok']); self.assertEqual(result['code'],1002)
            self.assertEqual(self.repo('stats'),before)
        claim=self.repo('claim',kind='item',key='item')
        self.assertFalse(self.call('mediaRepository.open', itemLimit=2)['ok'])
        self.assertFalse(self.call('mediaRepository.finish', ticket=str(claim['ticket']))['ok'])
        self.assertFalse(self.repo('claim',kind='item',key='item')['owner'])

    def test_freshness_keeps_strict_and_distinct_snapshot_progress_boundaries(self):
        for ttl in (-1, 0, 900, 3600, 604800, 2592000):
            for age in (-1, 0, ttl-0.125, ttl, ttl+0.125):
                for source in ('memory','disk','network'):
                    self.assertEqual(self.repo('freshness',kind='snapshot',source=source,age=age,ttl=ttl),source!='disk' and age<ttl)
                for present in (False,True):
                    self.assertEqual(self.repo('freshness',kind='progress',present=present,age=age,ttl=ttl),not present or age>ttl)
        self.assertFalse(self.call('mediaRepository.freshness',kind='snapshot',source='other',age=0,ttl=1)['ok'])

    def test_database_open_recovery_adoption_size_and_removal(self):
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory)
            for suffix in ('','-wal','-shm'): (root/('Media.sqlite'+suffix)).write_bytes(b'corrupt')
            (root/'original-report.txt').write_text('retained')
            opened=self.success('metadataDatabase.open',directory=directory)
            self.assertTrue(opened['rebuilt']); self.assertTrue(opened['firstError'])
            self.success('cache.touchTenant',tenantId='t',kind='jellyfin',now=1)
            self.success('cache.saveItems',tenantId='t',items=[dict(id='exact',name='作品',kind='movie',year=9223372036854775807)],now=2,requestStartedAt=1)
            self.assertEqual(self.success('cache.item',tenantId='t',itemId='exact')['payload']['year'],9223372036854775807)
            self.assertEqual(self.success('config.export')['config']['mediaDatabasePath'],opened['path'])
            expected=sum(p.stat().st_size for p in [root/('Media.sqlite'+suffix) for suffix in ('','-wal','-shm')] if p.exists())
            self.assertEqual(self.success('metadataDatabase.size',directory=directory),expected)
            self.success('metadataDatabase.remove',directory=directory)
            self.assertTrue(all(not (root/('Media.sqlite'+suffix)).exists() for suffix in ('','-wal','-shm')))
            self.assertEqual((root/'original-report.txt').read_text(),'retained')
            self.assertEqual(self.success('metadataDatabase.size',directory=directory),0)
            self.assertEqual(self.call('cache.itemCount',tenantId='t')['code'],1401)

    def test_database_unrecoverable_path_and_bad_arguments_do_not_touch_other_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory); parent=root/'parent-file'; parent.write_text('retained')
            result=self.call('metadataDatabase.open',directory=str(parent)); self.assertFalse(result['ok']); self.assertEqual(result['code'],1402)
            self.assertEqual(parent.read_text(),'retained')
            for value in (None,False,1,[],{}):
                result=self.call('metadataDatabase.open',directory=value); self.assertFalse(result['ok']); self.assertEqual(result['code'],1002)
            absent=root/'absent'
            self.assertEqual(self.success('metadataDatabase.size',directory=str(absent)),0)
            self.assertFalse(absent.exists())

for name in list(vars(NetworkContract)):
    if name.startswith('test_'): setattr(MediaRepositoryContract,name,None)
if __name__=='__main__':
    import unittest
    unittest.main(defaultTest="MediaRepositoryContract",verbosity=2)
