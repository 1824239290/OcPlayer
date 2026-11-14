import ctypes,hashlib,json,os,tempfile,time
from pathlib import Path
library=ctypes.CDLL(os.environ['OCP_CORE_LIBRARY_PATH'])
library.ocp_core_create.argtypes=[ctypes.c_char_p];library.ocp_core_create.restype=ctypes.c_void_p
library.ocp_call.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p];library.ocp_call.restype=ctypes.c_void_p
library.ocp_string_free.argtypes=[ctypes.c_void_p];library.ocp_core_destroy.argtypes=[ctypes.c_void_p]
with tempfile.TemporaryDirectory(prefix='ocp-diag-stress-') as temporary:
 root=Path(temporary);logs=root/'logs';logs.mkdir();(logs/'diagnostics.jsonl').write_bytes(b'\xff'*(8*1024*1024))
 core=library.ocp_core_create(b'{}')
 try:
  args=dict(logDirectory=str(logs),outputPath=str(root/'export.txt'),headerLines=['fixture'],bodyByteBudget=8*1024*1024,traces=[],username='fixture')
  start=time.monotonic();pointer=library.ocp_call(core,b'diag.export',json.dumps(args).encode())
  try:reply=json.loads(ctypes.string_at(pointer))
  finally:library.ocp_string_free(pointer)
  assert reply['ok'],reply
  elapsed=time.monotonic()-start;output=(root/'export.txt').read_bytes()
  assert len(output)==8*1024*1024*3+9
  assert output[:9]==b'fixture\n\n' and output[9:]==b'\xef\xbf\xbd'*(8*1024*1024)
  print(json.dumps(dict(rawBodyBytes=8*1024*1024,outputBytes=len(output),seconds=elapsed,sha256=hashlib.sha256(output).hexdigest())))
 finally:library.ocp_core_destroy(core)
