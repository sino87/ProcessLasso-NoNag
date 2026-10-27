import base64
import copy
import json
import pathlib
import sys
import tempfile
import unittest
import struct

sys.path.insert(0,str(pathlib.Path(__file__).parents[1]/'scripts'))
from publish_upstream import publish


class FakeGitHub:
    repository='owner/repo'

    def __init__(self):
        self.pulls=[]; self.branch=False; self.files={}; self.blobs={}; self.calls=[]; self.fail_pr=False

    def api(self,method,path,data=None,missing_ok=False):
        self.calls.append((method,path,data))
        if method=='GET':
            if path.startswith('pulls?'): return self.pulls
            if path=='': return {'default_branch':'main'}
            if path=='git/ref/heads/main': return {'object':{'sha':'base'}}
            if path.startswith('git/ref/heads/'): return {'object':{'sha':'candidate'}} if self.branch else None
            if path=='git/commits/base': return {'tree':{'sha':'base-tree'}}
            if path.startswith('contents/'):
                name=path[len('contents/'):].split('?')[0]
                return {'content':base64.b64encode(self.files[name].encode()).decode()}
            if path.startswith('compare/'): return {'files':[{'filename':p} for p in self.files]}
        if path=='git/blobs':
            sha=str(len(self.blobs)); self.blobs[sha]=data['content']; return {'sha':sha}
        if path=='git/trees':
            self.files={e['path']:self.blobs[e['sha']] for e in data['tree']}; return {'sha':'new-tree'}
        if path=='git/commits': return {'sha':'new-commit'}
        if path=='git/refs': self.branch=True; return {}
        if path=='pulls':
            if self.fail_pr: raise RuntimeError('Temporary PR failure')
            pr={'number':1,'state':'open','html_url':'https://github.com/owner/repo/pull/1'}
            self.pulls.append(pr); return pr
        raise AssertionError((method,path))


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=pathlib.Path(self.temp.name)
        (self.root/'.github').mkdir(); (self.root/'src').mkdir()
        self.state_path=self.root/'.github/upstream-state.json'
        self.state_path.write_text(json.dumps({'NotifiedHashes':[],'LastError':''}))
        self.readme='| Automated static check | Old |\n| Manual test | Keep me |\n'
        (self.root/'README.md').write_text(self.readme)
        (self.root/'src/profiles.json').write_text('[]')
        self.profile={'Version':'19.0.0.1','VmValidated':False,'OriginalHash':'a'*64,'PatchedHash':'b'*64,
                      'Patches':[{'Name':'window-restore-nag','Offset':100,'Before':'744d','After':'eb4d'},
                                 {'Name':'startup-offer','Offset':200,'Before':'0f85d9000000','After':'e9da00000090'},
                                 {'Name':'startup-nag','Offset':500,'Before':'7538','After':'eb38'}]}
        self.report={'Status':'review','Version':'19.0.0.1','ExecutableHash':'a'*64,'Reason':'Unknown hash','ErrorKey':'',
                     'Analysis':{'Status':'candidate','Reason':'Matched','AnalyzerHash':'c'*64,'Profile':self.profile,'Evidence':[],'Templates':['d'*64]},'CandidateValidated':True}
        for patch in self.profile['Patches']:
            before=bytes.fromhex(patch['Before']); rva=patch['Offset']+0xC00
            displacement=struct.unpack('<b',before[1:])[0] if len(before)==2 else struct.unpack('<i',before[2:])[0]
            self.report['Analysis']['Evidence'].append({'Name':patch['Name'],'Rva':rva,'TargetRva':rva+len(before)+displacement,
                                                      'Before':patch['Before'],'After':patch['After'],'PredicateRva':123,
                                                      'BeforeInstruction':'je 0x140001000','AfterInstructions':['jmp 0x140001000']})
        self.github=FakeGitHub(); self.messages=[]

    def run_publish(self,send=None): publish(self.report,self.root,self.github,send or self.messages.append,'https://github.com/owner/repo/actions/runs/1')
    def state(self): return json.loads(self.state_path.read_text())

    def test_candidate_one_pr_one_notification_no_readme_update(self):
        self.run_publish(); self.run_publish()
        self.assertEqual(len(self.github.pulls),1); self.assertEqual(len(self.messages),1)
        self.assertEqual((self.root/'README.md').read_text(),self.readme)
        self.assertEqual(set(self.github.files),{'src/profiles.json','docs/candidates/'+'a'*64+'.md'})
        self.assertFalse(json.loads(self.github.files['src/profiles.json'])[0]['VmValidated'])

    def test_delivery_failure_retains_pr_and_retries(self):
        def failed(_): raise RuntimeError('Delivery failed')
        with self.assertRaises(RuntimeError): self.run_publish(failed)
        self.assertEqual(len(self.state()['Candidates']),1)
        self.assertFalse(self.state()['EventsDelivered'])
        self.run_publish(); self.assertEqual(len(self.github.pulls),1); self.assertEqual(len(self.messages),1)

    def test_closed_pr_not_recreated(self):
        self.run_publish(); self.github.pulls[0]['state']='closed'
        self.run_publish(); self.assertEqual(len(self.github.pulls),1)
        self.assertEqual(self.state()['Candidates']['a'*64]['State'],'closed')

    def test_orphan_branch_recovered_without_overwrite(self):
        self.github.fail_pr=True
        with self.assertRaises(RuntimeError): self.run_publish()
        self.github.fail_pr=False; self.run_publish()
        self.assertEqual(sum(1 for m,p,_ in self.github.calls if m=='POST' and p=='git/refs'),1)

    def test_human_edited_orphan_branch_refused(self):
        self.github.fail_pr=True
        with self.assertRaises(RuntimeError): self.run_publish()
        self.github.fail_pr=False; self.github.files['src/profiles.json']='human edit'
        with self.assertRaises(RuntimeError): self.run_publish()

    def test_legacy_review_does_not_suppress_candidate(self):
        self.state_path.write_text(json.dumps({'NotifiedHashes':['a'*64],'LastError':''}))
        self.run_publish(); self.assertEqual(len(self.messages),1)

    def test_legacy_review_stays_suppressed_until_reason_changes(self):
        self.state_path.write_text(json.dumps({'NotifiedHashes':['a'*64],'LastError':''}))
        self.report['Analysis']={'Status':'inconclusive','Reason':'missing-route','AnalyzerHash':'c'*64}
        self.run_publish(); self.run_publish(); self.assertFalse(self.messages)
        self.report['Analysis']['Reason']='ambiguous-route'; self.run_publish(); self.assertEqual(len(self.messages),1)

    def test_inconclusive_repeats_and_changed_reason(self):
        self.report['Analysis']={'Status':'inconclusive','Reason':'missing-route','AnalyzerHash':'c'*64}
        self.run_publish(); self.run_publish(); self.assertEqual(len(self.messages),1)
        self.report['Analysis']['Reason']='ambiguous-route'; self.run_publish(); self.assertEqual(len(self.messages),2)
        self.assertFalse(self.github.calls)

    def test_error_suppression_and_recovery(self):
        self.report.update(Status='error',ErrorKey='analysis')
        self.run_publish(); self.run_publish(); self.assertEqual(len(self.messages),1)
        self.report.update(Status='pass'); self.run_publish()
        self.assertEqual(len(self.messages),2); self.assertEqual(self.state()['LastError'],'')
        text=(self.root/'README.md').read_text()
        self.assertIn('19.0.0.1 x64',text); self.assertIn('| Manual test | Keep me |',text)

    def test_validation_required(self):
        self.report['CandidateValidated']=False
        with self.assertRaises(ValueError): self.run_publish()
        self.assertFalse(self.github.calls)

    def test_candidate_evidence_tampering_refused(self):
        self.report['Analysis']['Evidence'][0]['TargetRva']+=1
        with self.assertRaises(ValueError): self.run_publish()
        self.assertFalse(self.github.calls)

    def test_stale_branch_refuses_candidate_creation(self):
        self.github.expected_revision='different-commit'
        with self.assertRaises(RuntimeError): self.run_publish()
        self.assertFalse(self.github.branch)


if __name__=='__main__': unittest.main()
