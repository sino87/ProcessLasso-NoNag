import argparse
import hashlib
import json
import os
import pathlib
import re
import urllib.request


def dump(value):
    return json.dumps(value,indent=2,sort_keys=True)+'\n'


def save(path,value):
    temporary=path.with_suffix('.tmp')
    temporary.write_text(dump(value),encoding='utf-8')
    temporary.replace(path)


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


def update_readme(root, report):
    version, release = report['Version'], report['NoNagRelease']
    if not re.fullmatch(r'\d+\.\d+\.\d+\.\d+', version) or not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?', release):
        raise ValueError('Invalid checked version or release')
    for name in ('ExecutableHash', 'DllHash', 'CheckerRevision'):
        if not re.fullmatch('[a-f0-9]{64}', report.get(name, '')):
            raise ValueError('Missing compatibility identity')
    path = root/'README.md'
    text = path.read_bytes().decode('utf-8')
    pattern = r'(?m)^\| Automated Compatibility Check \|[^\r\n]*'
    if len(re.findall(pattern, text)) != 1:
        raise ValueError('README check row unavailable')
    updated = re.sub(pattern, f'| Automated Compatibility Check | Process Lasso {version} x64 |', text)
    if updated != text:
        path.write_bytes(updated.encode('utf-8'))


def publish(report, root, send, run_url):
    if report.get('Schema') != 3 or report.get('Status') not in ('pass','review','error'):
        raise ValueError('Invalid compatibility report')
    if report.get('Development'):
        return
    state_path = root/'.github/upstream-state.json'
    state = json.loads(state_path.read_text(encoding='utf-8-sig'))
    if state.get('Schema') != 3:
        state = {'Schema':3,'EventsDelivered':[],'LastFailure':''}
    identity = {key:report.get(key,'') for key in ('Status','Version','ExecutableHash','DllHash','NoNagRelease','CheckerRevision','Reason','ErrorKey')}
    key = hashlib.sha256(json.dumps(identity,sort_keys=True).encode()).hexdigest()
    try:
        if report['Status'] == 'pass':
            update_readme(root,report)
            if state['LastFailure']:
                send(f"Process Lasso NoNag: Compatibility check recovered\nProcess Lasso: {report['Version']}\nNoNag: {report['NoNagRelease']}\n{run_url}")
                state['LastFailure'] = ''
        else:
            if key not in state['EventsDelivered']:
                label = 'Analysis required' if report['Status'] == 'review' else 'Check error'
                send(f"Process Lasso NoNag: {label}\nProcess Lasso: {report['Version']}\nNoNag: {report['NoNagRelease']}\n{report['Reason']}\n{run_url}")
                state['EventsDelivered'].append(key)
            state['LastFailure'] = key
    finally:
        save(state_path,state)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--report',type=pathlib.Path,required=True)
    args = parser.parse_args()
    try:
        repository, run_id = os.environ['GITHUB_REPOSITORY'], os.environ['GITHUB_RUN_ID']
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',repository) or not run_id.isdecimal():
            raise ValueError('Invalid workflow identity')
        report = json.loads(args.report.read_text(encoding='utf-8-sig'))
        publish(report,pathlib.Path(__file__).parents[1],send_discord,f'https://github.com/{repository}/actions/runs/{run_id}')
        return 1 if report['Status']=='error' else 0
    except Exception:
        print('Publication failed. Check the report, README row, state file and webhook configuration. Secret details are not logged.')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
