#!/usr/bin/env python3
"""Fail closed unless official AOJIT input metadata and admitted digests match.
Reading assembly is static verification only; this script never runs guest code.
"""
import argparse,hashlib,json,sys
from pathlib import Path
from image_info import info
p=argparse.ArgumentParser();p.add_argument('deps_dir',type=Path);args=p.parse_args()
root=args.deps_dir.resolve();lock=root/'aot/images.lock.json'
if not lock.is_file():raise SystemExit('ERROR: AOJIT images.lock.json missing; cannot claim an AOJIT build.')
manifest=json.loads(lock.read_text());assert manifest['ish_commit']=='0fd17a135e78b7a0cf08a4f5831217bbb76ed22f'
missing=[row['file'] for row in manifest['images'] if not (root/'aot'/row['file']).is_file()]
if missing:
 print('ERROR: required pre-recorded AOJIT images are not supplied ('+str(len(missing))+' missing).',file=sys.stderr)
 print('The upstream Git tree excludes these .S files. Supply compatible images and reviewed SHA256 digests; an empty archive is NOT an AOJIT implementation.',file=sys.stderr)
 for name in missing:print('  '+name,file=sys.stderr)
 raise SystemExit(2)
for row in manifest['images']:
 path=root/'aot'/row['file'];data=info(str(path))
 for key in ['build_id','module','family','abi']:
  expected=row[key] if key!='abi' else manifest['abi']
  if data[key]!=expected:raise SystemExit('ERROR: '+row['file']+' mismatch for '+key)
 expected=row.get('sha256')
 if not expected or len(expected)!=64:raise SystemExit('ERROR: '+row['file']+' has no independently admitted SHA256 digest.')
 h=hashlib.sha256()
 with path.open('rb') as f:
  for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
 if h.hexdigest()!=expected:raise SystemExit('ERROR: '+row['file']+' SHA256 mismatch')
 if not data['symbol'] or not data['translations'] or data['translations']<=0:raise SystemExit('ERROR: '+row['file']+' has no translations/symbol')
 print('PASS:',row['file'],'metadata and admitted digest')
actual={x.name for x in (root/'aot').glob('aot_*.S')};expected={x['file'] for x in manifest['images']}
if actual!=expected:raise SystemExit('ERROR: unreviewed extra AOJIT assembly image')
print('PASS: all AOJIT inputs verified; no empty-library fallback permitted.')
