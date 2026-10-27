import argparse
import base64
import hashlib
import json
import os
import pathlib
import re
import subprocess
import urllib.request

from patch_profiles import validate_profile, validate_analysis


def dump(value):
    return json.dumps(value,indent=2,sort_keys=True)+'\n'


def save(path,value):
    temporary=path.with_suffix('.tmp')
    temporary.write_text(dump(value),encoding='utf-8')
    temporary.replace(path)


class GitHub:
    def __init__(self,repository,expected_revision=''):
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',repository):
            raise ValueError('Invalid repository')
        self.repository=repository
        self.expected_revision=expected_revision

    def api(self,method,path,data=None,missing_ok=False):
        args=['gh','api','--method',method,f'repos/{self.repository}/{path}']
        if data is not None: args+=['--input','-']
        result=subprocess.run(args,input=json.dumps(data) if data is not None else None,
                              text=True,capture_output=True,timeout=60,check=False)
        if result.returncode:
            if missing_ok and 'HTTP 404' in result.stderr: return None
            raise RuntimeError('GitHub request failed; inspect workflow permissions and repository settings.')
        return json.loads(result.stdout) if result.stdout.strip() else None


def candidate_document(analysis):
    profile=analysis['Profile']
    return (f"# Candidate: Process Lasso {profile['Version']} x64\n\n"
            'VM validation is pending. Do not merge or use on the host before reviewing and testing this candidate.\n\n'
            '## Static evidence\n\n```json\n'+dump(analysis)+'```\n\n'
            '## Manual checks\n\n'
            '- [ ] Review all three routes and branch targets.\n'
            '- [ ] Reproduce reminders in the unmodified VM baseline.\n'
            '- [ ] Confirm startup, normal launch, and tray redisplay behavior.\n'
            '- [ ] Confirm settings, process-list updates, and GUI restart.\n'
            '- [ ] Test older-backup replacement and Restore original.\n'
            '- [ ] Set VmValidated to true and update manual-test documentation before merging.\n')


def ensure_pr(github,analysis,root,run_url,retry_closed=False):
    profile=validate_profile(analysis['Profile'])
    if profile['VmValidated']: raise ValueError('Candidate cannot be VM-validated')
    identity=profile['OriginalHash']
    branch='auto/patch-'+identity
    owner=github.repository.split('/')[0]
    pulls=github.api('GET',f'pulls?state=all&head={owner}:{branch}&per_page=100')
    open_pr=next((p for p in pulls if p['state']=='open'),None)
    if open_pr: return {'Number':open_pr['number'],'Url':open_pr['html_url'],'State':'open'}
    if pulls and not retry_closed:
        latest=pulls[0]
        return {'Number':latest['number'],'Url':latest['html_url'],'State':'closed'}
    registry=json.loads((root/'src/profiles.json').read_text(encoding='utf-8'))
    if any(profile['OriginalHash'] in (p['OriginalHash'],p['PatchedHash']) or profile['PatchedHash'] in (p['OriginalHash'],p['PatchedHash']) for p in registry):
        raise ValueError('Candidate hashes already registered')
    document_path=f'docs/candidates/{identity}.md'
    files={'src/profiles.json':dump(registry+[profile]),document_path:candidate_document(analysis)}
    branch_ref=github.api('GET',f'git/ref/heads/{branch}',missing_ok=True)
    if branch_ref:
        for name,content in files.items():
            existing=github.api('GET',f'contents/{name}?ref={branch}')
            if base64.b64decode(existing['content']).decode('utf-8') != content:
                raise RuntimeError('Candidate branch contains edits; automatic replacement refused.')
        default=github.api('GET','')['default_branch']
        comparison=github.api('GET',f'compare/{default}...{branch}')
        if any(f['filename'] not in files for f in comparison.get('files',[])):
            raise RuntimeError('Candidate branch has unrelated changes.')
    else:
        default=github.api('GET','')['default_branch']
        base_ref=github.api('GET',f'git/ref/heads/{default}')
        parent=base_ref['object']['sha']
        if getattr(github,'expected_revision','') and parent != github.expected_revision:
            raise RuntimeError('Default branch changed; rerun analysis before creating a candidate branch.')
        base_commit=github.api('GET',f'git/commits/{parent}')
        entries=[]
        for name,content in files.items():
            blob=github.api('POST','git/blobs',{'content':content,'encoding':'utf-8'})
            entries.append({'path':name,'mode':'100644','type':'blob','sha':blob['sha']})
        tree=github.api('POST','git/trees',{'base_tree':base_commit['tree']['sha'],'tree':entries})
        commit=github.api('POST','git/commits',{'message':f"Add candidate for Process Lasso {profile['Version']}",'tree':tree['sha'],'parents':[parent]})
        github.api('POST','git/refs',{'ref':f'refs/heads/{branch}','sha':commit['sha']})
    default=github.api('GET','')['default_branch']
    created=github.api('POST','pulls',{'title':f"Candidate: Process Lasso {profile['Version']} x64 ({identity[:12]})",
                                     'head':branch,'base':default,'draft':True,
                                     'body':f"Three recognized routes matched and candidate transaction tests passed. VM validation is pending.\n\nSource SHA-256: `{identity}`\n\n[Analysis and preview ZIP]({run_url})\n\nSee `{document_path}` for evidence and the manual checklist. PR workflows may require approval. Do not merge before VM validation."})
    return {'Number':created['number'],'Url':created['html_url'],'State':'open'}


def send_discord(content):
    webhook=os.environ.get('DISCORD_WEBHOOK_URL','')
    if not re.fullmatch(r'https://(?:discord\.com|discordapp\.com)/api/webhooks/\d+/[A-Za-z0-9_-]+',webhook):
        raise RuntimeError('Discord webhook secret is missing or invalid.')
    payload=json.dumps({'content':content[:1900],'allowed_mentions':{'parse':[]}}).encode()
    request=urllib.request.Request(webhook,data=payload,headers={'Content-Type':'application/json','User-Agent':'ProcessLasso-NoNag'},method='POST')
    try:
        with urllib.request.urlopen(request,timeout=30) as response:
            if not 200 <= response.status < 300: raise RuntimeError('Discord delivery failed.')
    except Exception:
        raise RuntimeError('Discord delivery failed; no webhook details are logged.') from None


def publish(report,root,github,send,run_url,retry_closed=False):
    state_path=root/'.github/upstream-state.json'
    state=json.loads(state_path.read_text(encoding='utf-8-sig'))
    state.setdefault('Schema',2)
    state.setdefault('EventsDelivered',[])
    state.setdefault('Candidates',{})
    state.setdefault('AnalysisOutcomes',{})
    events=[]
    if report['Status']=='error':
        key=report['ErrorKey']
        if state['LastError'] != key: events.append(('error:'+key,'Check error',None))
    else:
        if state['LastError']: events.append(('recovery:'+state['LastError'],'Check recovered',None))
        if report['Status']=='review':
            identity=report['ExecutableHash']
            if not re.fullmatch('[a-f0-9]{64}',identity): raise ValueError('Invalid executable hash')
            analysis=validate_analysis(report['Analysis'])
            if analysis['Status']=='candidate':
                profile=validate_profile(analysis['Profile'])
                if not report.get('CandidateValidated') or profile['OriginalHash'] != identity or profile['Version'] != report['Version']:
                    raise ValueError('Candidate validation missing')
                record=ensure_pr(github,analysis,root,run_url,retry_closed)
                state['Candidates'][identity]=record
                if record['State']=='open': events.append((f"candidate:{identity}:{record['Number']}",'Patch candidate generated; VM validation required',record['Url']))
            elif analysis['Status']=='inconclusive':
                reason=analysis['Reason']
                key='review:'+identity+':'+hashlib.sha256(reason.encode()).hexdigest()
                if identity in state['NotifiedHashes'] and identity not in state['AnalysisOutcomes']:
                    if key not in state['EventsDelivered']: state['EventsDelivered'].append(key)
                else: events.append((key,'Analysis required',None))
            else:
                raise ValueError('Invalid analysis result')
            state['AnalysisOutcomes'][identity]={'Status':analysis['Status'],'Reason':analysis['Reason'],'Revision':analysis['AnalyzerHash']}
    try:
        for key,label,link in events:
            is_transient=key.startswith(('error:','recovery:'))
            if not is_transient and key in state['EventsDelivered']: continue
            reason=report['Reason'] if report['Status']=='error' else report.get('Analysis',{}).get('Reason',report['Reason'])
            content=f"Process Lasso NoNag: {label}\nVersion: {report['Version']}\n{reason}\n"
            if link: content+=link+'\n'
            content+=run_url
            send(content)
            if key.startswith('error:'): state['LastError']=report['ErrorKey']
            elif key.startswith('recovery:'): state['LastError']=''
            else: state['EventsDelivered'].append(key)
        if report['Status']=='pass':
            version=report['Version']
            if not re.fullmatch(r'\d+\.\d+\.\d+\.\d+',version): raise ValueError('Invalid version')
            readme_path=root/'README.md'
            text=readme_path.read_bytes().decode('utf-8')
            pattern=r'(?m)^\| Automated static check \|[^\r\n]*'
            if len(re.findall(pattern,text)) != 1: raise ValueError('README check row unavailable')
            updated=re.sub(pattern,f'| Automated static check | Process Lasso {version} x64 |',text)
            if updated != text: readme_path.write_bytes(updated.encode('utf-8'))
    finally:
        save(state_path,state)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--report',type=pathlib.Path,required=True)
    parser.add_argument('--retry-closed',action='store_true')
    args=parser.parse_args()
    root=pathlib.Path(__file__).parents[1]
    try:
        repository=os.environ['GITHUB_REPOSITORY']
        run_id=os.environ['GITHUB_RUN_ID']
        if not run_id.isdecimal(): raise ValueError('Invalid run ID')
        github=GitHub(repository,os.environ['GITHUB_SHA'])
        run_url=f'https://github.com/{repository}/actions/runs/{run_id}'
        report=json.loads(args.report.read_text(encoding='utf-8-sig'))
        publish(report,root,github,send_discord,run_url,args.retry_closed)
        return 1 if report['Status']=='error' else 0
    except Exception:
        print('Publication failed. Check PR permissions, candidate state, and webhook configuration. Secret details are not logged.')
        return 1


if __name__=='__main__': raise SystemExit(main())
