#!/usr/bin/env python3
"""Inventory production dispatch arms; test modules and emitted events are excluded."""
from pathlib import Path
import json, re, sys
ROOT = Path(__file__).resolve().parents[1]
# A prefix records the composition root's delegate, not a new API declaration.
DELEGATES = {
 'bangumiAccount.':['crates/ocp-bangumi/src/account.rs'],
 'bangumiAuthFlow.':['crates/ocp-bangumi/src/auth_flow.rs'],
 'bangumiProgress.':['crates/ocp-bangumi/src/progress.rs'],
 'bangumiSync.':['crates/ocp-bangumi/src/sync.rs'],
 'bangumiStore.':['crates/ocp-store/src/bangumi.rs'],
 'cache.':['crates/ocp-store/src/cache.rs'],
 'danmakuCache.':['crates/ocp-danmaku/src/cache.rs'],
 'danmakuFlow.':['crates/ocp-danmaku/src/flow.rs'],
 'danmakuIntro.':['crates/ocp-danmaku/src/intro.rs'],
 'introIDs.':['crates/ocp-danmaku/src/identity.rs'],
 'introIdentity.':['crates/ocp-danmaku/src/identity.rs'],
 'introLearning.':['crates/ocp-danmaku/src/intro.rs'],
 'introProvider.':['crates/ocp-danmaku/src/providers.rs'],
 'moviepilotAccount.':['crates/ocp-moviepilot/src/account.rs'],
 'moviepilotFlow.':['crates/ocp-moviepilot/src/flow.rs'],
 'mediaRepository.':['crates/ocp-store/src/repository.rs'],
 'mediaRepository.flow.':['crates/ocp-store/src/repository/flow.rs'],
 'mediaRepository.compose.':['crates/ocp-store/src/repository/composition.rs'],
 'mediaRepository.progress.':['crates/ocp-store/src/repository/progress.rs'],
 'tmdbEnrichment.':['crates/ocp-tmdb/src/enrichment.rs'],
 'tmdbEnrichment.batch.':['crates/ocp-tmdb/src/enrichment.rs'],
}
TOKEN = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|r(#+)?"[\s\S]*?"\1|"(?:\\.|[^"\\])*"|\w+|=>|==|[^\s]',re.M)
def tokens(source):
 return [(m.group(),m.start(),m.end()) for m in TOKEN.finditer(source) if not m.group().startswith(('//','/*'))]
def production(source):
 # Remove only cfg(test) modules, including ones between production helpers.
 for m in reversed(list(re.finditer(r'#\[cfg\(test\)\]\s*mod\s+\w+\s*\{',source))):
  depth=1
  for token,begin,end in tokens(source[m.end():]):
   depth += (token=='{')-(token=='}')
   if depth==0:
    source=source[:m.start()]+source[m.end()+end:];break
 return source

def dispatch(source):
 source=production(source); result=set(); ts=tokens(source)
 for i,(token,_,_) in enumerate(ts):
  if token=='match' and i+1<len(ts) and ts[i+1][0] in ('method','m'):
   j=i+2; extra=''
   while j<len(ts) and ts[j][0]!='{':
    if ts[j][0]=='trim_start_matches' and j+2<len(ts):
     try: extra=json.loads(ts[j+2][0])
     except Exception: pass
    j+=1
   depth=1; arm=[]; j+=1; body=False
   while j<len(ts) and depth:
    t=ts[j][0]
    if depth==1:
     if t=='=>':
      for name in arm:
       if name.startswith('"'):
        value=json.loads(name)
        if re.fullmatch(r'[\w]+(?:\.[\w]+)*',value):result.add(extra+value)
      arm=[];body=True
     elif t==',':arm=[];body=False
     elif not body:arm.append(t)
    before=depth
    depth+=(t in '([{')-(t in ')]}')
    if t=='}' and before==2 and depth==1:arm=[];body=False
    j+=1
  if token=='method' and i+2<len(ts) and ts[i+1][0]=='==' and ts[i+2][0].startswith('"'):
   result.add(json.loads(ts[i+2][0]))
 # Network command allow-lists are matches!(method, ...).
 for match in re.finditer(r'matches!\(\s*method\s*,([\s\S]*?)\)',source):
  result.update(re.findall(r'"([\w.]+)"',match.group(1)))
 return result

def inventory():
 main='crates/ocp-core/src/lib.rs'; rows={}
 for method in dispatch((ROOT/main).read_text(encoding='utf-8')):
  if '.' in method or method=='ping':rows[method]=main
 for prefix,paths in DELEGATES.items():
  for path in paths:
   text=production((ROOT/path).read_text(encoding='utf-8'))
   sections = {
    'introIdentity.': ('pub fn policy(', 'pub struct IDStore'),
    'introIDs.': ('    pub fn call(', None),
    'danmakuIntro.': ('pub fn call(', 'pub struct LearningStore'),
    'introLearning.': ('    pub fn call(', None),
    'tmdbEnrichment.': ('    pub fn call(', '    fn batch('),
   }
   if prefix in sections:
    start,end=sections[prefix];text=text[text.index(start):]
    if end is not None:text=text[:text.index(end)]
   names=dispatch(text)
   # Batch commands in this file dispatch on the same suffix parameter.
   if prefix=='tmdbEnrichment.batch.':
    text=production((ROOT/path).read_text(encoding='utf-8'));start=text.index('fn batch(')
    names=dispatch(text[start:])
   for name in names:rows[prefix+name]=path
 for method in ['settings.backup.capabilities','settings.backup.snapshot','settings.backup.decode','settings.backup.prepare','settings.backup.restore','settings.backup.summary','diag.exportFile','diag.exportFile.capabilities','introIDs.resolve','endpoint.probe','moviepilot.clearSessions']:
  rows[method]=main
 # This service dispatches complete command names rather than stripped suffixes.
 library='crates/ocp-core/src/library.rs'
 for method in dispatch((ROOT/library).read_text(encoding='utf-8')):
  rows[method]=library
 return dict(sorted(rows.items()))
if __name__=='__main__':
 print(json.dumps(inventory(),indent=2,ensure_ascii=False))
