"""Complete account/profile sequencing and atomic credential guards via C ABI."""
import unittest
import bangumi_sync_contract as fixture


class AuthFlowContract(unittest.TestCase):
    setUpClass = classmethod(fixture.SyncContract.setUpClass.__func__)
    setUp = fixture.SyncContract.setUp
    tearDown = fixture.SyncContract.tearDown
    call = fixture.SyncContract.call
    success = fixture.SyncContract.success

    def start(self, operation, **args):
        return self.success('bangumiAuthFlow.start', operation=operation, **args)

    def resume(self, step, response=True):
        return self.success('bangumiAuthFlow.resume', token=step['token'], sequence=step['sequence'], response=response)

    def failure(self, step):
        return self.success('bangumiAuthFlow.fail', token=step['token'], sequence=step['sequence'])

    def credential(self):
        self.success('bangumiAccount.oauth.prepare', state='fixture')
        exchange = self.success('bangumiAccount.oauth.consume', state='fixture')
        committed = self.success('bangumiAccount.commit', kind='oauth', generation=exchange['generation'])
        snapshot = self.success('bangumiAccount.snapshot')
        return {'generation': committed['generation'], 'identity': snapshot['identityGeneration']}

    def test_login_sequences_profile_after_exchange_and_retires_database_work(self):
        sync = self.success('bangumiSync.start', operation='collections')
        progress = self.success('bangumiProgress.start', operation='ensureSubject', subjectId=1)
        step = self.start('exchange')
        self.assertEqual(step['effect'], 'retireWork')
        self.assertEqual(self.success('bangumiSync.stats')['active'], 0)
        self.assertEqual(self.success('bangumiProgress.stats')['active'], 0)
        step = self.resume(step)
        self.assertEqual(step['effect'], 'exchange')
        step = self.resume(step, self.credential())
        self.assertEqual(step['effect'], 'fetchProfile')
        step = self.resume(step)
        self.assertEqual(step['effect'], 'commitProfile')
        done = self.resume(step)
        self.assertTrue(done['success']); self.assertTrue(done['result'])
        self.assertEqual(self.success('bangumiAuthFlow.stats')['active'], 0)

    def test_profile_failure_rolls_back_only_the_login_generation_and_keeps_original_failure(self):
        exchange = self.resume(self.start('exchange'))
        credential = self.credential()
        profile = self.resume(exchange, credential)
        rollback = self.failure(profile)
        self.assertTrue(rollback['cleanup'])
        self.assertEqual(rollback['arguments']['expectedGeneration'], credential['generation'])
        cleared = self.success('bangumiAccount.invalidate', generation=credential['generation'], operationRevision=profile['operationRevision'])
        done = self.resume(rollback, {'generation': cleared['generation']})
        self.assertFalse(done['success'])
        exchange = self.resume(self.start('exchange'))
        credential = self.credential()
        commit = self.resume(self.resume(exchange, credential))
        rollback = self.failure(commit)
        refreshed = self.success('bangumiAccount.commit', kind='refresh', generation=credential['generation'])
        rejected = self.success('bangumiAccount.invalidate', generation=credential['generation'], operationRevision=rollback['operationRevision'])
        self.assertFalse(rejected['accepted'])
        self.assertFalse(self.resume(rollback, {'generation': None})['success'])
        self.assertEqual(self.success('bangumiAccount.snapshot')['generation'], refreshed['generation'])

    def test_profile_survives_transparent_refresh_but_not_another_identity_or_operation(self):
        self.credential()
        profile = self.resume(self.start('refreshProfile'))
        generation = self.success('bangumiAccount.snapshot')['generation']
        self.success('bangumiAccount.commit', kind='refresh', generation=generation)
        commit = self.resume(profile)
        self.assertTrue(self.resume(commit)['success'])
        profile = self.resume(self.start('refreshProfile'))
        self.credential()
        self.assertEqual(self.call('bangumiAuthFlow.validate', token=profile['token'], sequence=profile['sequence'])['code'], 1003)
        profile = self.resume(self.start('refreshProfile'))
        self.start('logout')
        self.assertEqual(self.call('bangumiAuthFlow.resume', token=profile['token'], sequence=profile['sequence'], response=True)['code'], 1003)

    def test_logout_clears_profile_before_credentials_and_skips_new_account_database(self):
        step = self.resume(self.start('logout'))
        self.assertEqual(step['effect'], 'clearProfile')
        step = self.resume(step)
        self.assertEqual(step['effect'], 'clearCredentials')
        cleared = self.success('bangumiAccount.invalidate', operationRevision=step['operationRevision'])
        database = self.resume(step, {'generation': cleared['generation']})
        self.assertEqual(database['effect'], 'clearDatabase')
        self.assertTrue(self.failure(database)['success'])
        step = self.resume(self.resume(self.start('logout')))
        cleared = self.success('bangumiAccount.invalidate', operationRevision=step['operationRevision'])
        self.credential()
        done = self.resume(step, {'generation': cleared['generation']})
        self.assertTrue(done['done']); self.assertFalse(done['result'])

    def test_passive_invalidation_checks_auth_operation_and_cleared_credential_before_ui_retirement(self):
        before = self.success('bangumiAccount.snapshot')['operationRevision']
        self.assertTrue(self.start('invalidateSession', authenticated=False)['done'])
        self.assertEqual(self.success('bangumiAccount.snapshot')['operationRevision'], before)
        step = self.start('invalidateSession', authenticated=True, expectedGeneration=99)
        self.assertTrue(self.resume(step, {'generation': None})['done'])
        self.assertEqual(self.success('bangumiAccount.snapshot')['operationRevision'], before)
        step = self.start('invalidateSession', authenticated=True, expectedGeneration=0)
        clear = self.success('bangumiAccount.invalidate', generation=0, operationRevision=before)
        work = self.resume(step, {'generation': clear['generation']})
        self.assertEqual(work['effect'], 'retireWork')
        self.assertEqual(work['operationRevision'], before+1)
        profile = self.resume(work)
        self.assertEqual(profile['effect'], 'clearProfile')
        self.assertTrue(self.resume(profile)['success'])

    def test_atomic_clear_rejects_bad_or_stale_operation_without_retiring_credentials(self):
        revision = self.success('bangumiAccount.operation.begin')
        before = self.success('bangumiAccount.snapshot')
        for operation in (None, -1, 1.5, True, str(revision), 2**64):
            self.assertEqual(self.call('bangumiAccount.invalidate', operationRevision=operation)['code'], 1002)
            self.assertEqual(self.success('bangumiAccount.snapshot'), before)
        for args in ({'operationRevision': revision-1}, {'operationRevision': revision, 'generation': 9}):
            self.assertFalse(self.success('bangumiAccount.invalidate', **args)['accepted'])
            self.assertEqual(self.success('bangumiAccount.snapshot'), before)
        self.assertTrue(self.success('bangumiAccount.invalidate', operationRevision=revision, generation=before['generation'])['accepted'])

    def test_integer_receipts_bad_acknowledgement_and_cancellation_are_non_consuming(self):
        step = self.start('exchange')
        self.assertEqual(self.call('bangumiAuthFlow.resume', token=step['token'], sequence=step['sequence'], response=False)['code'], 1002)
        self.assertEqual(self.call('bangumiAuthFlow.validate', token=step['token'], sequence=step['sequence']+1)['code'], 1002)
        old = step; step = self.resume(step)
        self.assertEqual(self.call('bangumiAuthFlow.resume', token=old['token'], sequence=old['sequence'], response=True)['code'], 1002)
        for receipt in ({'generation': None, 'identity': 0}, {'generation': 1.5, 'identity': 0}, {'generation': 2**64, 'identity': 0}):
            self.assertEqual(self.call('bangumiAuthFlow.resume', token=step['token'], sequence=step['sequence'], response=receipt)['code'], 1002)
        profile = self.resume(step, {'generation': 2**64-1, 'identity': 0})
        rollback = self.failure(profile)
        self.assertEqual(rollback['arguments']['expectedGeneration'], 2**64-1)
        self.assertTrue(self.success('bangumiAuthFlow.cancel', token=rollback['token']))
        self.assertFalse(self.success('bangumiAuthFlow.cancel', token=rollback['token']))
        self.assertEqual(self.call('bangumiAuthFlow.validate', token=rollback['token'], sequence=rollback['sequence'])['code'], 1003)
        exchange = self.resume(self.start('exchange'))
        self.assertEqual(self.call('bangumiAuthFlow.resume', token=exchange['token'], sequence=exchange['sequence'], response={'generation': 0, 'identity': 1})['code'], 1003)
        self.assertEqual(self.success('bangumiAuthFlow.stats')['active'], 0)
        self.assertEqual(self.call('bangumiAuthFlow.validate', token=exchange['token'], sequence=exchange['sequence'])['code'], 1003)

    def test_directory_bound_does_not_prevent_new_login_from_retiring_old_observers(self):
        flows = [self.start('invalidateSession', authenticated=True, expectedGeneration=0) for _ in range(1024)]
        self.assertEqual(self.call('bangumiAuthFlow.start', operation='invalidateSession', authenticated=True, expectedGeneration=0)['code'], 1002)
        current = self.start('exchange')
        self.assertGreater(current['token'], flows[-1]['token'])
        self.assertEqual(self.success('bangumiAuthFlow.stats')['active'], 1)
        self.assertFalse(self.success('bangumiAuthFlow.cancel', token=flows[0]['token']))
        before = self.success('bangumiAccount.snapshot')
        for args in ({'operation': 'other'}, {'operation': 'invalidateSession', 'authenticated': True},
                     {'operation': 'invalidateSession', 'authenticated': True, 'expectedGeneration': -1}):
            self.assertEqual(self.call('bangumiAuthFlow.start', **args)['code'], 1002)
            self.assertEqual(self.success('bangumiAccount.snapshot'), before)


if __name__ == '__main__': unittest.main()
