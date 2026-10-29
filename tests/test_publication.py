import copy
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(pathlib.Path(__file__).parents[1]/'scripts'))
import publish_upstream as publisher

ROOT = pathlib.Path(__file__).parents[1]


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        (self.root/'.github').mkdir()
        self.state_path = self.root/'.github/upstream-state.json'
        self.state_path.write_text('{"Schema":3,"EventsDelivered":[],"LastFailure":""}')
        self.readme = self.root/'README.md'
        self.readme.write_bytes(b'| Check | Last checked version |\r\n|---|---|\r\n| Automated Compatibility Check | - |\r\n| Manual Check | Process Lasso 18.4.0.48 x64 |\r\n')
        self.original = self.readme.read_bytes()
        self.report = dict(Schema=3,Status='pass',Version='18.4.0.48',NoNagRelease='v1.0.0',ExecutableHash='a'*64,DllHash='b'*64,CheckerRevision='c'*64,Reason='Verified',ErrorKey='',Development=False)
        self.messages = []

    def publish(self, report=None, send=None):
        publisher.publish(report or self.report,self.root,send or self.messages.append,'https://github.com/a/b/actions/runs/1')

    def test_only_automated_row_updated(self):
        self.publish()
        text = self.readme.read_bytes()
        self.assertIn(b'| Automated Compatibility Check | Process Lasso 18.4.0.48 x64 |\r\n',text)
        self.assertIn(b'| Manual Check | Process Lasso 18.4.0.48 x64 |\r\n',text)
        self.assertEqual(self.messages,[])

    def test_development_never_publishes(self):
        self.report['Development'] = True
        for status in ('pass','review','error'):
            self.report['Status']=status
            self.publish()
        self.assertEqual(self.readme.read_bytes(),self.original)
        self.assertFalse(self.messages)

    def test_failures_notify_once_and_do_not_update_readme(self):
        for status in ('review','error'):
            self.report['Status']=status
            self.publish()
            self.publish()
        self.assertEqual(len(self.messages),2)
        self.assertEqual(self.readme.read_bytes(),self.original)

    def test_failure_identity_changes_trigger_notifications(self):
        self.report['Status']='review'
        self.publish()
        for field in ('ExecutableHash','DllHash','CheckerRevision','NoNagRelease','Reason','ErrorKey'):
            report=copy.deepcopy(self.report)
            report[field]+='changed'
            self.publish(report)
        self.assertEqual(len(self.messages),7)

    def test_error_reports_deduplicate_across_source_revisions(self):
        metadata = self.root/'metadata.html'
        metadata.write_text('unrecognized metadata', encoding='utf-8')
        revisions = []
        for source_revision in ('a'*40, 'b'*40):
            result = subprocess.run([
                'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                str(ROOT/'scripts/Check-Upstream.ps1'), '-MetadataPath', str(metadata),
                '-OutputDirectory', str(self.root/'reports'),
            ], capture_output=True, text=True, env={**os.environ, 'GITHUB_SHA':source_revision}, timeout=30)
            self.assertEqual(result.returncode, 1, result.stdout+result.stderr)
            report = json.loads((self.root/'reports/report.json').read_text(encoding='utf-8-sig'))
            self.assertEqual(report['Status'], 'error')
            self.assertEqual(report['ErrorKey'], 'metadata')
            self.assertEqual(report['SourceRevision'], source_revision)
            revisions.append(report['CheckerRevision'])
            self.publish(report)
            if len(revisions) == 1:
                saved = self.state_path.read_bytes()
        expected = hashlib.sha256(b''.join((ROOT/'scripts'/name).read_bytes() for name in (
            'check_compatibility.py', 'pe_image.py', 'compatibility-reference.json',
        ))).hexdigest()
        self.assertEqual(revisions, [expected, expected])
        self.assertEqual(len(self.messages), 1)
        self.assertEqual(self.state_path.read_bytes(), saved)

    def test_failed_delivery_is_retried(self):
        self.report['Status']='review'
        with self.assertRaises(RuntimeError):
            self.publish(send=lambda _:(_ for _ in ()).throw(RuntimeError('delivery failed')))
        self.assertEqual(json.loads(self.state_path.read_text())['EventsDelivered'],[])
        self.publish()
        self.assertEqual(len(self.messages),1)

    def test_recovery_and_delivery_retry(self):
        report=copy.deepcopy(self.report)
        report['Status']='error'
        self.publish(report)
        with self.assertRaises(RuntimeError):
            self.publish(send=lambda _:(_ for _ in ()).throw(RuntimeError('delivery failed')))
        self.assertTrue(json.loads(self.state_path.read_text())['LastFailure'])
        self.publish()
        self.publish()
        self.assertEqual(len(self.messages),2)

    def test_invalid_version_or_hash_refused(self):
        for field in ('Version','NoNagRelease','ExecutableHash','DllHash','CheckerRevision'):
            report=copy.deepcopy(self.report)
            report[field]='invalid'
            with self.assertRaises(ValueError): self.publish(report)
        self.assertEqual(self.readme.read_bytes(),self.original)

    def test_missing_or_duplicate_row_refused(self):
        for content in ('missing',self.original.decode()*2):
            self.readme.write_text(content)
            with self.assertRaises(ValueError): self.publish()

    def test_state_save_failure_allows_retry(self):
        self.report['Status']='review'
        with patch.object(publisher,'save',side_effect=OSError('disk full')):
            with self.assertRaises(OSError): self.publish()
        self.publish()
        self.assertEqual(len(self.messages),2)

    def test_discord_disables_mentions_and_redacts_failures(self):
        with patch.dict('os.environ',{'DISCORD_WEBHOOK_URL':'https://discord.com/api/webhooks/123/secret'}):
            with patch.object(publisher.urllib.request,'urlopen',side_effect=RuntimeError('secret')) as send:
                with self.assertRaisesRegex(RuntimeError,'no webhook details'):
                    publisher.send_discord('message')
                payload=json.loads(send.call_args.args[0].data)
                self.assertEqual(payload['allowed_mentions'],{'parse':[]})


if __name__=='__main__': unittest.main()
