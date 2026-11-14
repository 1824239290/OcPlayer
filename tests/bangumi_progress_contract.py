"""Subject/progress effects composed with the real SQL store through the C ABI."""
import unittest
import uuid
import bangumi_sync_contract as fixture


class ProgressContract(unittest.TestCase):
    setUpClass = classmethod(fixture.SyncContract.setUpClass.__func__)
    setUp = fixture.SyncContract.setUp
    tearDown = fixture.SyncContract.tearDown
    call = fixture.SyncContract.call
    success = fixture.SyncContract.success

    def start(self, operation, **args):
        return self.success('bangumiProgress.start', operation=operation, **args)

    def resume(self, step, response=True):
        return self.success('bangumiProgress.resume', token=step['token'], sequence=step['sequence'], response=response)

    def apply(self, step, now=1000):
        return self.success('bangumiProgress.apply', token=step['token'], sequence=step['sequence'], now=now)

    def failure(self, step, reason='HTTP fixture failure'):
        return self.success('bangumiProgress.fail', token=step['token'], sequence=step['sequence'], reason=reason)

    def seed(self, owner=1, count=2, status=0, collection_type=3):
        subject = fixture.subject(owner)
        subject['interest']['type'] = collection_type
        self.success('bangumiStore.saveSubject', item=subject, authoritativeInterest=True)
        episodes = [fixture.episode(i + 1, owner) for i in range(count)]
        for i, episode in enumerate(episodes):
            episode['sort'] = float(i + 1)
            episode['collection'] = {'status': status, 'updatedAt': 1}
        self.success('bangumiStore.replaceEpisodes', subjectId=owner, items=episodes, authoritativeCollection=True, now=1)
        return subject, episodes

    def drive(self, step, handler=lambda effect, args: True):
        effects = []
        for _ in range(100):
            if step['done']:
                self.assertTrue(step['success'], step)
                return step, effects
            effects.append((step['effect'], step['arguments']))
            step = self.apply(step) if step['effect'] == 'database' else self.resume(step, handler(step['effect'], step['arguments']))
        self.fail('progress failed to terminate')

    def test_ensure_uses_presence_counts_complete_paging_and_single_use_sql(self):
        step = self.start('ensureSubject', subjectId=1)
        self.assertEqual(step['effect'], 'database')
        self.assertEqual(self.call('bangumiProgress.resume', token=step['token'], sequence=step['sequence'], response=fixture.subject())['code'], 1002)
        old = step
        step = self.apply(step)
        self.assertEqual(step['effect'], 'subject')
        self.assertEqual(self.call('bangumiProgress.apply', token=old['token'], sequence=old['sequence'], now=1)['code'], 1002)
        step = self.resume(step, fixture.subject())
        step = self.apply(step)
        step = self.apply(step)
        self.assertEqual(step['arguments'], {'subjectId': 1, 'limit': 1000, 'offset': 0})
        step = self.resume(step, {'data': [fixture.episode(2**63-1)], 'total': 2000})
        self.assertEqual(step['arguments']['offset'], 1000)
        step = self.resume(step, {'data': [], 'total': 2000})
        step = self.apply(step)
        self.assertEqual(step['arguments'], {'subjectId': 1, 'membership': False})
        self.assertTrue(self.resume(step)['done'])
        rows = self.success('bangumiStore.episodes', subjectId=1)
        self.assertEqual(rows[0]['id'], 2**63-1)
        _, effects = self.drive(self.start('ensureSubject', subjectId=1))
        self.assertEqual([e for e, _ in effects], ['database', 'database', 'notify'])
        force = self.apply(self.apply(self.start('ensureSubject', subjectId=1, refreshEpisodes=True)))
        self.assertEqual(force['effect'], 'episodes')

    def test_reconcile_tri_state_preserves_interest_and_authoritative_episode_status(self):
        for state in ('unknown', 'notCollected', 'collected'):
            with self.subTest(state=state):
                original, episodes = self.seed(status=2)
                remote = fixture.subject(); remote.pop('interest')
                episode = fixture.episode()
                lookup = {'state': state, 'reason': 'unavailable'}
                if state == 'collected':
                    lookup['interest'] = dict(original['interest'], type=4, updatedAt=100)
                def handler(effect, args):
                    return {'subject': remote, 'lookup': lookup, 'episodes': {'data': [episode], 'total': 1}}.get(effect, True)
                _, effects = self.drive(self.start('reconcileSubject', subjectId=1), handler)
                self.assertNotIn('notify', [e for e, _ in effects])
                stored = self.success('bangumiStore.subject', subjectId=1)
                self.assertEqual(stored['interest']['type'], 4 if state == 'collected' else 3)
                self.assertEqual(self.success('bangumiStore.episodes', subjectId=1)[0]['collection']['status'], 2)
                self.drive(self.start('reconcileSubject', subjectId=1, authoritativeCollection=True), handler)
                self.assertEqual(self.success('bangumiStore.episodes', subjectId=1)[0]['collection']['status'], 0)

    def test_watching_state_matrix_and_failed_prelude_preserve_explicit_episode_intent(self):
        for typ in range(6):
            self.seed()
            step = self.start('ensureWatching', subjectId=1)
            step = self.resume(step, {'state': 'collected', 'interest': {'type': typ}})
            done, effects = self.drive(step)
            self.assertEqual(done['result'], typ not in (2, 3))
            self.assertEqual('subjectMutation' in [e for e, _ in effects], typ not in (2, 3))
        for state in ('unknown', 'notCollected'):
            step = self.resume(self.start('ensureWatching', subjectId=1), {'state': state})
            done, _ = self.drive(step)
            self.assertEqual(done['result'], state == 'notCollected')
        step = self.apply(self.start('updateEpisode', episodeId=1, type=2, prepareWatching=True))
        step = self.resume(step, {'state': 'notCollected'})
        self.assertEqual(step['arguments']['type'], 3)
        step = self.failure(step)
        self.assertEqual(step['effect'], 'episodeMutation')
        _, effects = self.drive(step)
        self.assertIn(('notify', {'subjectId': 1, 'membership': False}), effects)
        self.assertEqual(self.success('bangumiStore.episodes', subjectId=1)[0]['collection']['status'], 2)

    def test_batch_marks_sorted_mains_before_reconcile_and_keeps_success_on_read_failure(self):
        self.seed(count=3)
        step = self.resume(self.start('updateEpisode', episodeId=2, type=2, batch=True))
        step = self.apply(step)
        self.assertEqual(step['effect'], 'notify')
        rows = self.success('bangumiStore.episodes', subjectId=1)
        self.assertEqual([e['collection']['status'] for e in rows], [2, 2, 0])
        self.assertEqual(self.success('bangumiStore.subject', subjectId=1)['interest']['epStatus'], 2)
        step = self.resume(step)
        self.assertEqual(step['effect'], 'subject')
        step = self.failure(step)
        self.assertEqual(step['arguments']['kind'], 'batchReconcileFailed')
        done = self.resume(step)
        self.assertTrue(done['success'])
        missing, effects = self.drive(self.start('updateEpisode', episodeId=999, type=2, batch=True))
        self.assertTrue(missing['success'])
        self.assertNotIn('notify', [e for e, _ in effects])

    def test_refresh_after_read_failure_promotes_only_nonempty_watched_mains_and_remote_doing(self):
        for count, status, typ in ((0, 2, 3), (2, 0, 3), (2, 2, 1), (2, 2, 2), (2, 2, 3), (2, 2, 4), (2, 2, 5)):
            with self.subTest(count=count, status=status, typ=typ):
                self.seed(count=count, status=status, collection_type=typ)
                step = self.failure(self.start('refreshAfterProgress', subjectId=1))
                done, effects = self.drive(step, lambda effect, args: {'state': 'collected', 'interest': {'type': typ}} if effect == 'lookup' else True)
                promoted = count > 0 and status == 2 and typ == 3
                self.assertEqual('subjectMutation' in [e for e, _ in effects], promoted)
                self.assertEqual(self.success('bangumiStore.subject', subjectId=1)['interest']['type'], 2 if promoted else typ)
                self.assertEqual(effects[-1], ('notify', {'subjectId': 1, 'membership': True}))
        self.seed(status=2)
        step = self.apply(self.resume(self.failure(self.start('refreshAfterProgress', subjectId=1))))
        step = self.resume(step, {'state': 'collected', 'interest': {'type': 3}})
        self.assertEqual(step['effect'], 'subjectMutation')
        step = self.failure(step)
        self.assertEqual(step['arguments']['kind'], 'promotionFailed')
        _, effects = self.drive(step)
        self.assertEqual(effects[-1][0], 'notify')
        self.assertEqual(self.success('bangumiStore.subject', subjectId=1)['interest']['type'], 3)

    def test_manual_type_rating_signed_ids_and_invalid_inputs(self):
        owner = 2**63-1
        self.seed(owner=owner)
        _, effects = self.drive(self.start('updateSubject', subjectId=owner, type=4))
        self.assertEqual(effects[-1], ('notify', {'subjectId': owner, 'membership': True}))
        _, effects = self.drive(self.start('updateRating', subjectId=owner, rate=10))
        self.assertEqual(effects[-1], ('notify', {'subjectId': owner, 'membership': False}))
        stored = self.success('bangumiStore.subject', subjectId=owner)
        self.assertEqual((stored['interest']['type'], stored['interest']['rate']), (4, 10))
        for args in ({'operation': 'updateRating', 'subjectId': owner, 'rate': 11},
                     {'operation': 'updateEpisode', 'episodeId': 1, 'type': 4},
                     {'operation': 'updateSubject', 'subjectId': owner, 'type': -1},
                     {'operation': 'ensureSubject'}):
            self.assertEqual(self.call('bangumiProgress.start', **args)['code'], 1002)
        step = self.resume(self.start('updateRating', subjectId=owner, rate=1))
        self.assertEqual(self.call('bangumiProgress.apply', token=step['token'], sequence=step['sequence'], now=-(2**63))['code'], 1002)
        self.assertEqual(self.call('bangumiProgress.apply', token=step['token'], sequence=step['sequence'], now=0.5)['code'], 1002)
        self.assertTrue(self.resume(self.apply(step))['done'])

    def test_sql_failure_rolls_back_and_retains_receipt_until_explicit_failure(self):
        _, original = self.seed()
        step = self.start('loadEpisodes', subjectId=1, authoritativeCollection=True)
        invalid = fixture.episode(3); invalid['id'] = 'invalid'
        step = self.resume(step, {'data': [fixture.episode(1), invalid], 'total': 2})
        result = self.call('bangumiProgress.apply', token=step['token'], sequence=step['sequence'], now=1000)
        self.assertFalse(result['ok'], result)
        self.assertEqual(len(self.success('bangumiStore.episodes', subjectId=1)), len(original))
        result2 = self.call('bangumiProgress.apply', token=step['token'], sequence=step['sequence'], now=1000)
        self.assertFalse(result2['ok'], result2)
        done = self.failure(step)
        self.assertTrue(done['done']); self.assertFalse(done['success'])
        self.assertEqual(self.success('bangumiProgress.stats')['active'], 0)

    def test_account_retirement_rejects_late_http_sql_and_does_not_reuse_tokens(self):
        for method, args in (('bangumiSync.invalidate', {}), ('bangumiStore.clearAccountLocalState', {}),
                             ('bangumiAccount.operation.begin', {}), ('bangumiAccount.invalidate', {}),
                             ('settings.set', {}), ('config.import', {})):
            step = self.resume(self.start('updateRating', subjectId=1, rate=5))
            # A changed DB path is needed; an unchanged path deliberately preserves work.
            if method in ('settings.set', 'config.import'):
                args = {'config': {'bangumiDatabasePath': f'/tmp/ocp-progress-contract-{uuid.uuid4()}.sqlite'}}
            self.success(method, **args)
            self.assertEqual(self.call('bangumiProgress.apply', token=step['token'], sequence=step['sequence'], now=1)['code'], 1002)
            new = self.start('ensureWatching', subjectId=1)
            self.assertGreater(new['token'], step['token'])
            self.success('bangumiSync.invalidate')
            self.assertEqual(self.call('bangumiProgress.resume', token=new['token'], sequence=new['sequence'], response={'state': 'notCollected'})['code'], 1002)
            self.assertFalse(self.success('bangumiProgress.cancel', token=new['token']))

    def test_invalid_lookup_is_non_consuming_and_directory_has_a_finite_bound(self):
        step = self.start('ensureWatching', subjectId=1)
        for lookup in ({'state': 'collected'}, {'state': 'collected', 'interest': {'type': 7}}, {'state': 'other'}):
            self.assertEqual(self.call('bangumiProgress.resume', token=step['token'], sequence=step['sequence'], response=lookup)['code'], 1002)
        self.assertFalse(self.resume(step, {'state': 'unknown'})['result'])
        flows = [self.start('ensureWatching', subjectId=1) for _ in range(1024)]
        self.assertEqual(self.call('bangumiProgress.start', operation='ensureWatching', subjectId=1)['code'], 1002)
        self.assertTrue(self.success('bangumiProgress.cancel', token=flows[0]['token']))
        new = self.start('ensureWatching', subjectId=1)
        self.assertGreater(new['token'], flows[-1]['token'])
        self.success('bangumiSync.invalidate')
        self.assertEqual(self.success('bangumiProgress.stats')['active'], 0)


if __name__ == '__main__':
    unittest.main()
