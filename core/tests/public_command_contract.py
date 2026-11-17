#!/usr/bin/env python3
"""Whole command surface negative-boundary and ownership checks against the C ABI."""
import ctypes, importlib.util, json, math, os, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('surface', ROOT/'Scripts/audit-core-surface.py')
surface = importlib.util.module_from_spec(spec);spec.loader.exec_module(surface)

class PublicCommandContract(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.inventory=json.loads((ROOT/'docs/public-command-inventory.json').read_text())
  cls.ffi=ctypes.CDLL(os.environ['OCP_CORE_LIBRARY_PATH'])
  f=cls.ffi
  f.ocp_core_create.argtypes=[ctypes.c_char_p];f.ocp_core_create.restype=ctypes.c_void_p
  f.ocp_core_destroy.argtypes=[ctypes.c_void_p]
  f.ocp_call.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p];f.ocp_call.restype=ctypes.c_void_p
  f.ocp_string_free.argtypes=[ctypes.c_void_p]
  f.ocp_snapshot.argtypes=[ctypes.c_void_p,ctypes.c_char_p];f.ocp_snapshot.restype=ctypes.c_void_p
  f.ocp_last_error_message.restype=ctypes.c_void_p
  f.ocp_attach_surface.argtypes=[ctypes.c_void_p,ctypes.c_uint64,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_double,ctypes.c_uint32]
  f.ocp_resize_surface.argtypes=[ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_double]
  f.ocp_render_tick.argtypes=[ctypes.c_void_p,ctypes.c_double]
 def setUp(self):
  self.core=self.ffi.ocp_core_create(b'{}');self.assertTrue(self.core)
 def tearDown(self):self.ffi.ocp_core_destroy(self.core)
 def take(self,pointer):
  if not pointer:return None
  try:return ctypes.string_at(pointer).decode()
  finally:self.ffi.ocp_string_free(pointer)
 def call(self,method,arguments):
  value=self.take(self.ffi.ocp_call(self.core,method.encode(),json.dumps(arguments).encode()))
  self.assertIsNotNone(value, self.take(self.ffi.ocp_last_error_message()))
  reply=json.loads(value)
  self.assertEqual(set(reply),{'ok','code','retryable','message','data'})
  return reply
 def test_inventory_matches_production_routing(self):
  self.assertEqual(self.inventory,surface.inventory())
  self.assertGreater(len(self.inventory),300)
 def test_every_command_rejects_nonobject_arguments_before_side_effects(self):
  for method in self.inventory:
   for invalid in [None, [], [1], False, 7, 'bad']:
    with self.subTest(method=method,value=invalid):
     reply=self.call(method,invalid);self.assertEqual(reply['code'],1002);self.assertFalse(reply['ok']);self.assertFalse(reply['retryable'])
  self.assertTrue(self.call('ping',{})['ok'])
 def test_every_command_rejects_invalid_request_ownership_before_dispatch(self):
  for method in self.inventory:
   for invalid in [None, False, 7, [], {}, '', 'a\0b']:
    with self.subTest(method=method,value=invalid):
     reply=self.call(method,{'requestId':invalid});self.assertEqual(reply['code'],1002);self.assertFalse(reply['ok'])
 def test_local_strict_dtos_accept_envelope_ownership_and_release_it(self):
  for method in ['preferences.schema','settings.backup.capabilities','diag.exportFile.capabilities']:
   for _ in range(2):
    self.assertTrue(self.call('request.prepare',{'requestId':'reused'})['ok'])
    self.assertTrue(self.call(method,{'requestId':'reused'})['ok'])
  with tempfile.TemporaryDirectory() as temp:
   logs=Path(temp)/'logs';logs.mkdir()
   reply=self.call('diag.exportFile',{'requestId':'file','logDirectory':str(logs),'outputPath':str(Path(temp)/'out.log'),'headerLines':['fixture'],'traces':[],'username':'fixture'})
   self.assertTrue(reply['ok'],reply)
   self.assertTrue(self.call('request.prepare',{'requestId':'file'})['ok'])
   self.assertTrue(self.call('request.cancel',{'requestId':'file'})['ok'])
   self.assertEqual(self.call('ping',{'requestId':'file'})['code'],1003)
   self.assertTrue(self.call('ping',{'requestId':'file'})['ok'])
 def test_surface_rejects_nonfinite_values_without_mutation(self):
  for scale in [0,-1,math.nan,math.inf]:
   self.ffi.ocp_attach_surface(self.core,1,10,10,scale,1)
   self.assertIn('scale',self.take(self.ffi.ocp_last_error_message()))
   state=json.loads(self.take(self.ffi.ocp_snapshot(self.core,b'core')))
   self.assertFalse(state['surfaceAttached'])
  self.ffi.ocp_attach_surface(self.core,1,10,10,1,1)
  self.ffi.ocp_resize_surface(self.core,10,10,math.inf)
  self.assertIn('scale',self.take(self.ffi.ocp_last_error_message()))
  self.ffi.ocp_render_tick(self.core,math.nan)
  self.assertIn('time',self.take(self.ffi.ocp_last_error_message()))
  self.assertTrue(self.call('ping',{})['ok'])
 def test_runtime_preference_schema_and_boundaries(self):
  rows=self.call('preferences.schema',{})['data']['keys'];self.assertEqual(len(rows),29)
  def resolve(key,value,present=True):
   result=self.call('preferences.resolve',dict(key=key,value=value,present=present));self.assertTrue(result['ok'],result);return result['data']['value']
  for row in rows:self.assertEqual(resolve(row['key'],None,False),row['default'])
  self.assertEqual(resolve('playback.outroRetentionSeconds',0),0)
  self.assertEqual(resolve('playback.outroRetentionSeconds',7),10)
  self.assertEqual(resolve('playback.rate',99),2)
  self.assertEqual(resolve('playback.rate',-1),0.5)
  self.assertEqual(resolve('playback.rate','nan'),'nan')
  self.assertEqual(resolve('playback.subtitleOutlineWidth',99),0)
  self.assertIsNone(resolve('playback.subtitleBold',None,False))
  self.assertEqual(resolve('playback.subtitleBold',False),False)
  self.assertIsNone(resolve('playback.subtitlePrimaryColor',0))
  self.assertEqual(resolve('playback.subtitlePrimaryColor',2**32-1),2**32-1)
  self.assertFalse(self.call('preferences.resolve',dict(key='bad',present=True,value=0))['ok'])
if __name__=='__main__':unittest.main(verbosity=2)
