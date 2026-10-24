import argparse, json, os, sys, urllib.request, urllib.error
from pathlib import Path
BASE='https://api.github.com/repos/JudeGor1129/OpenMinis'
ROOT=Path('/var/minis/workspace/10-minis/openminis/artifacts')
ROOT.mkdir(exist_ok=True)
headers={'Accept':'application/vnd.github+json','User-Agent':'Minis-build-status'}
if os.environ.get('GITHUB'): headers['Authorization']='Bearer '+os.environ['GITHUB']
def get(path, binary=False):
    try:
        req=urllib.request.Request(BASE+path, headers=headers)
        with urllib.request.urlopen(req,timeout=20) as r:
            data=r.read()
        return data if binary else json.loads(data)
    except urllib.error.HTTPError as e:
        print('GitHub HTTP',e.code)
        return None
    except Exception as e:
        print('GitHub request failed:',type(e).__name__)
        return None
p=argparse.ArgumentParser();p.add_argument('--sha',default='152d8be');p.add_argument('--run');p.add_argument('--job-log');a=p.parse_args()
if a.job_log:
    data=get('/actions/jobs/'+a.job_log+'/logs', True)
    if data:
        out=ROOT/('job-'+a.job_log+'.log');out.write_bytes(data)
        lines=data.decode('utf-8-sig','replace').splitlines()
        for i,line in enumerate(lines):
            if 'error:' in line.lower() or 'FAIL:' in line or 'BUILD SUCCEEDED' in line or 'BUILD FAILED' in line:
                print('\n'.join(lines[max(0,i-1):i+3])[:1600])
        print('Saved:',out)
    sys.exit(0)
if a.run:
    run=get('/actions/runs/'+a.run)
else:
    data=get('/actions/workflows/ios15.yml/runs?branch=ios15-port&per_page=12')
    if not data: sys.exit(1)
    runs=[r for r in data.get('workflow_runs',[]) if r['head_sha'].startswith(a.sha)]
    if not runs:
        print('No run for expected SHA',a.sha);sys.exit(0)
    run=runs[0]
if not run:sys.exit(1)
print(json.dumps({k:run.get(k) for k in ['id','run_number','head_sha','status','conclusion','html_url','created_at']},ensure_ascii=False))
jobs=get('/actions/runs/'+str(run['id'])+'/jobs?per_page=100') or {}
for j in jobs.get('jobs',[]):
    print('JOB',j['id'],j['name'],j['status'],j['conclusion'])
    for s in j.get('steps',[]):
        if s['status']=='in_progress' or s.get('conclusion')=='failure': print(' STEP',s['number'],s['name'],s['status'],s['conclusion'])
arts=get('/actions/runs/'+str(run['id'])+'/artifacts') or {}
for art in arts.get('artifacts',[]):
    print('ARTIFACT',art['name'],round(art['size_in_bytes']/1048576,2),'MB', 'expired='+str(art['expired']))
    print(run['html_url']+'/artifacts/'+str(art['id']))
(ROOT/'build-status.json').write_text(json.dumps({'run':run,'jobs':jobs,'artifacts':arts},ensure_ascii=False))
