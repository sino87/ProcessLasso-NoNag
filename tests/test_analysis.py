import copy
import hashlib
import json
import pathlib
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(pathlib.Path(__file__).parents[1]/'scripts'))
from analyze_patch import Image, Inconclusive, analyze, apply_candidate, make_template
from patch_profiles import validate_profile
from capstone import Cs, CS_ARCH_X86, CS_MODE_64


class SyntheticImage(Image):
    def __init__(self, shift=0, mutation=None):
        self.base = 0x140000000
        self.version = '19.0.0.1'
        self.data = bytearray(0x2000)
        self.functions = []
        self.imports = {}
        self.decoded = {}; self.helpers = {}; self.tables = {}
        self.md = Cs(CS_ARCH_X86,CS_MODE_64); self.md.detail=True
        helper = 0x1800+shift
        self.functions.append((helper,helper+6))
        self.data[helper:helper+6]=bytes.fromhex('b801000000c3')
        self.sites=[]
        for name,rva,condition,resource in (
            ('window-restore-nag',0x100,0x74,0x291),
            ('startup-offer',0x400,0x85,0x13BF),
            ('startup-nag',0x900,0x75,0x291)
        ):
            rva += shift
            prefix=b'\xe8'+struct.pack('<i',helper-rva-5)+(b'\x84\xc0' if name=='window-restore-nag' else b'\x3c\x01')
            body=b'\x41\xb8'+struct.pack('<I',resource)+b'\x41\xb9'+struct.pack('<I',1000)
            body+=b'\x90'*(217-len(body) if name=='startup-offer' else 4)
            branch=(bytes((condition,len(body))) if condition != 0x85 else b'\x0f\x85'+struct.pack('<i',len(body)))
            code=prefix+branch+body+b'\x90\x90\xc3'
            if mutation=='condition' and name=='startup-nag':
                code=code[:7]+b'\x74'+code[8:]
            if mutation=='side-effect' and name=='startup-nag':
                code=code[:15]+b'\xcc'+code[16:]
            if mutation=='missing' and name=='startup-nag':
                continue
            self.data[rva:rva+len(code)]=code
            self.functions.append((rva,rva+len(code)))
            self.sites.append((name,self.base+rva+7))
            if mutation=='duplicate' and name=='startup-nag':
                duplicate=rva+0x200
                relocated=b'\xe8'+struct.pack('<i',helper-duplicate-5)+code[5:]
                self.data[duplicate:duplicate+len(relocated)]=relocated
                self.functions.append((duplicate,duplicate+len(relocated)))
        self.data=bytes(self.data)
        self.functions.sort(); self.starts=[s for s,_ in self.functions]
        self.pe=self

    def get_data(self,rva,size):
        return self.data[rva:rva+size]

    def get_offset_from_rva(self,rva):
        return rva

    def get_rva_from_offset(self,offset):
        return offset

    def executable(self,address):
        return any(s<=address-self.base<e for s,e in self.functions)


class AnalysisTests(unittest.TestCase):
    def setUp(self):
        self.resources={'reminder':'a'*64,'offer':'b'*64}
        self.resource_mock=patch('analyze_patch.resource_roles',return_value=self.resources)
        self.resource_mock.start(); self.addCleanup(self.resource_mock.stop)
        self.original=SyntheticImage()
        sites=[]
        for name,address in self.original.sites:
            ins=self.original.instructions(self.original.function(address))
            sites.append((name,next(i for i in ins if i.address==address)))
        self.profile,_=apply_candidate(self.original,sites)
        self.profile['VmValidated']=True
        self.template=make_template(self.original,None,self.profile)

    def test_relocated_candidate(self):
        image=SyntheticImage(0x30)
        result=analyze(image,None,[self.template])
        self.assertEqual(result['Status'],'candidate')
        self.assertFalse(result['Profile']['VmValidated'])
        self.assertEqual([p['Offset'] for p in result['Profile']['Patches']],[0x137,0x437,0x937])

    def test_changed_condition_missing_and_ambiguous_routes(self):
        for mutation in ('condition','side-effect','missing','duplicate'):
            with self.subTest(mutation=mutation), self.assertRaises(Inconclusive):
                analyze(SyntheticImage(mutation=mutation),None,[self.template])

    def test_changed_resources(self):
        with patch('analyze_patch.resource_roles',return_value={'reminder':'c'*64,'offer':'b'*64}), self.assertRaises(Inconclusive):
            analyze(SyntheticImage(),None,[self.template])

    def test_invalid_branch_target(self):
        image=SyntheticImage()
        data=bytearray(image.data); data[0x108]=1; image.data=bytes(data)
        with self.assertRaises(Inconclusive): analyze(image,None,[self.template])

    def test_different_shared_predicate_refused(self):
        image=SyntheticImage()
        data=bytearray(image.data)
        data[0x1C00:0x1C06]=bytes.fromhex('b801000000c3')
        data[0x901:0x905]=struct.pack('<i',0x1C00-0x900-5)
        image.data=bytes(data); image.functions.append((0x1C00,0x1C06)); image.starts=[s for s,_ in image.functions]
        with self.assertRaises(Inconclusive): analyze(image,None,[self.template])

    def test_changed_helper_and_unresolved_dispatch_refused(self):
        for code in (bytes.fromhex('b802000000c3'),bytes.fromhex('ffe090909090')):
            image=SyntheticImage(); data=bytearray(image.data); data[0x1800:0x1806]=code; image.data=bytes(data)
            with self.subTest(code=code.hex()),self.assertRaises(Inconclusive): analyze(image,None,[self.template])

    def test_nonexecutable_region_refused(self):
        image=SyntheticImage()
        image.executable=lambda address: False
        with self.assertRaises(Inconclusive): analyze(image,None,[self.template])

    def test_profile_rejects_modified_target_and_fields(self):
        for mutation in ('target','offset','extra','validated','hash'):
            profile=copy.deepcopy(self.profile)
            if mutation=='target': profile['Patches'][0]['After']='eb00'
            if mutation=='offset': profile['Patches'][1]['Offset']=profile['Patches'][0]['Offset']
            if mutation=='extra': profile['Command']='run anything'
            if mutation=='validated': profile['VmValidated']='true'
            if mutation=='hash': profile['PatchedHash']=profile['OriginalHash']
            with self.subTest(mutation=mutation), self.assertRaises(ValueError): validate_profile(profile)

    def test_deterministic_output(self):
        first=analyze(SyntheticImage(0x30),None,[self.template])
        second=analyze(SyntheticImage(0x30),None,[self.template])
        self.assertEqual(first,second)

    def test_malformed_pe(self):
        with tempfile.TemporaryDirectory() as directory:
            file=pathlib.Path(directory)/'broken.exe'; file.write_bytes(b'MZ'+b'\0'*100)
            with self.assertRaises(Exception): Image(file)


if __name__=='__main__': unittest.main()
