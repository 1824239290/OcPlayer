"""Gateway public C ABI checks; no external servers or credentials."""
import base64
import concurrent.futures
import time
from danmaku_server import Handler
from network_contract import NetworkContract

class DanmakuContract(NetworkContract):
    # Borrow the ABI/server lifetime helpers, not the unrelated network cases.
    def setUp(self):
        import threading
        from http.server import ThreadingHTTPServer
        self.server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        self.server.daemon_threads=True
        self.server.records=[]
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True)
        self.thread.start()
        self.base=f'http://127.0.0.1:{self.server.server_port}'
        self.core=self.ffi.ocp_core_create(b'{}')
        self.assertTrue(self.core)
    def exchange(self,path='/v1/search/anime',**args):
        return self.call('danmaku.exchange',gateway={'base_url':self.base,'api_key':'key','user_agent':'OcPlay/fixture'},url=self.base+path,httpMethod=args.pop('httpMethod','GET'),**args)
    def test_routes_raw_fields_headers_pool_and_queries(self):
        paths=['/v1/match','/v1/search/anime?keyword=%E4%B8%AD+%26','/v1/search/episodes?tmdbId=42&tmdbIdType=1&episode=S1','/v1/comments/42000001?withRelated=true&chConvert=0']
        for path in paths:
            args={'httpMethod':'POST','bodyBase64':base64.b64encode(b'{"fileHash":"abc"}').decode()} if path.endswith('match') else {}
            response=self.exchange(path,**args)
            self.assertTrue(response['ok'],response)
            self.assertEqual(response['data']['headers']['x-gateway-cache'],'HIT')
            import json
            data=json.loads(base64.b64decode(response['data']['bodyBase64']))
            if path.endswith('match'): self.assertEqual(data['matches'][0]['unknown'],{'x':[1,2]})
            if 'comments' in path: self.assertEqual([c['cid'] for c in data['comments']],[1,2,3])
        self.assertEqual(len({r['port'] for r in self.server.records}),1)
        self.assertTrue(all(r['key']=='key' and r['agent']=='OcPlay/fixture' for r in self.server.records))
        self.assertEqual(self.server.records[0]['body'],'{"fileHash":"abc"}')
    def test_errors_and_binary_never_replay(self):
        for status in [401,403,429,500,502,503,504]:
            r=self.exchange(f'/v1/search/anime?scenario=status{status}')
            self.assertTrue(r['ok'],r)
            self.assertEqual(r['data']['status'],status)
            self.assertEqual(r['data']['headers']['retry-after'],'0.01')
        r=self.exchange('/v1/search/anime?scenario=binary')
        self.assertEqual(base64.b64decode(r['data']['bodyBase64']),bytes([0,255,128,10]))
        self.assertEqual(len(self.server.records),8)
    def test_bad_origin_route_and_timeout_rejected_before_io(self):
        for path,args in [('/v1/comments/-1',{}),('/v1/comments/9223372036854775808',{}),('/v1/other',{}),('/v1/match',{'httpMethod':'DELETE'}),('/v1/search/anime',{'bodyBase64':'AA=='}),('/v1/search/anime',{'bodyBase64':'!'}),('/v1/search/anime',{'timeoutSeconds':0}),('/v1/search/anime',{'timeoutSeconds':301}),('/v1/search/anime',{'timeoutSeconds':'1'})]:
            self.assertEqual(self.exchange(path,**args)['code'],1002)
        r=self.call('danmaku.exchange',gateway={'base_url':self.base,'api_key':'k','user_agent':'a'},url='http://localhost:1/v1/search/anime',httpMethod='GET')
        self.assertEqual(r['code'],1002)
        self.assertEqual(self.server.records,[])
    def test_timeout_and_cancellation_interrupt_live_requests(self):
        r=self.exchange('/v1/search/anime?scenario=slow',timeoutSeconds=.05)
        self.assertEqual(r['code'],1503,r)
        with concurrent.futures.ThreadPoolExecutor() as pool:
            f=pool.submit(self.exchange,'/v1/search/anime?scenario=slow',requestId='danmaku-cancel')
            deadline=time.monotonic()+2
            while len(self.server.records)<2 and time.monotonic()<deadline: time.sleep(.005)
            self.success('request.cancel',requestId='danmaku-cancel')
            self.assertEqual(f.result(timeout=.3)['code'],1003)
        self.assertEqual(len(self.server.records),2)

# Inheritance only supplies utilities; remove inherited test cases from collection.
for name in list(vars(NetworkContract)):
    if name.startswith('test_'): setattr(DanmakuContract,name,None)
del NetworkContract
if __name__=='__main__':
    import unittest
    unittest.main(verbosity=2)
