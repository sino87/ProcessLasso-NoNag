import copy
import json
import os
import pathlib
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_64
sys.path.insert(0,str(pathlib.Path(__file__).parents[1]/'scripts'))
import check_compatibility as compatibility
from pe_image import Image, Inconclusive

ROOT=pathlib.Path(__file__).parents[1]
BUILD=ROOT/'build'
DLL=ROOT/'bin/version.dll'
HARNESS=BUILD/'tests/native/Release/dialog_harness.exe'


class CallbackTests(unittest.TestCase):
    def image(self, start=0x1000, targets=(24, 30), jump=b'\xff\xe1', truncate=False):
        code = (b'\x83\xfb\x01\x77\x19\x48\x8d\x15'+struct.pack('<i', -(start+12))
                +b'\x8b\x8c\x9a'+struct.pack('<i', start+36)+b'\x48\x03\xca'+jump
                +b'\xb8\x01\x00\x00\x00\xc3\xb8\x02\x00\x00\x00\xc3'
                +b''.join(struct.pack('<I', start+target) for target in targets))
        image = Image.__new__(Image)
        image.base = 0x140000000
        image.functions = [(start, start+len(code))]
        image.starts = [start]
        image.md = Cs(CS_ARCH_X86, CS_MODE_64)
        image.md.detail = True
        image.imports = {}
        image.pe = types.SimpleNamespace(
            get_data=lambda rva,size:code[rva-start:rva-start+size] if not (truncate and rva==start+36) else b'',
            get_section_by_rva=lambda rva:types.SimpleNamespace(Characteristics=0x20000000),
        )
        return image

    def normalized(self, image):
        return image.normalize_callback(image.base+image.starts[0])

    def test_table_relocation_preserves_callback(self):
        self.assertEqual(self.normalized(self.image()), self.normalized(self.image(start=0x2000)))

    def test_table_targets_are_compared(self):
        self.assertNotEqual(self.normalized(self.image()), self.normalized(self.image(targets=(30, 24))))

    def test_table_bytes_are_not_decoded_as_jumps(self):
        self.assertEqual(self.normalized(self.image()), self.normalized(self.image(start=0x1e0ff-24)))

    def test_invalid_or_missing_table_requires_review(self):
        for image in (self.image(targets=(25, 30)), self.image(truncate=True)):
            with self.subTest(image=image), self.assertRaises(Inconclusive):
                self.normalized(image)

    def test_unknown_indirect_jump_requires_review(self):
        with self.assertRaisesRegex(Inconclusive, 'indirect-jump'):
            self.normalized(self.image(jump=b'\xff\xe0'))


@unittest.skipUnless(HARNESS.exists() and DLL.exists(),'Build native tooling first')
class ImportTests(unittest.TestCase):
    def test_required_imports_are_resolved(self):
        image=Image(HARNESS)
        slots=compatibility.verify_imports(image,DLL)
        self.assertGreaterEqual(len(slots),4)

    def test_missing_export_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            dll=pathlib.Path(folder)/'version.dll'
            data=bytearray(DLL.read_bytes())
            pe=pefile.PE(data=data)
            exports=pe.DIRECTORY_ENTRY_EXPORT.struct
            offset=pe.get_offset_from_rva(exports.AddressOfFunctions+(9-exports.Base)*4)
            struct.pack_into('<I',data,offset,0)
            dll.write_bytes(data)
            with self.assertRaisesRegex(Inconclusive,'export-missing'):
                compatibility.verify_imports(Image(HARNESS),dll)

    def test_wrong_architecture_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            dll=pathlib.Path(folder)/'version.dll'
            data=bytearray(DLL.read_bytes())
            pe=struct.unpack_from('<I',data,0x3c)[0]
            struct.pack_into('<H',data,pe+4,0x14c)
            dll.write_bytes(data)
            with self.assertRaisesRegex(Inconclusive,'not-x64'):
                compatibility.verify_imports(Image(HARNESS),dll)

    def test_tls_callback_is_rejected_before_launch(self):
        image=Image(HARNESS)
        image.pe.DIRECTORY_ENTRY_TLS=types.SimpleNamespace(struct=types.SimpleNamespace(AddressOfCallBacks=image.base+0x1000))
        original=image.pe.get_data
        with patch.object(image.pe,'get_data',side_effect=lambda rva,size:struct.pack('<Q',image.base+0x1234) if rva==0x1000 and size==8 else original(rva,size)):
            with self.assertRaisesRegex(Inconclusive,'tls-callbacks'):
                compatibility.verify_imports(image,DLL)

    def test_native_probe_stops_before_tls_callback(self):
        fixture=BUILD/'tests/native/Release/tls_fixture.exe'
        pe=pefile.PE(data=fixture.read_bytes())
        self.assertTrue(pe.DIRECTORY_ENTRY_TLS.struct.AddressOfCallBacks)
        result=subprocess.run([str(BUILD/'tests/native/Release/loader_probe.exe'),str(fixture),hex(pe.OPTIONAL_HEADER.AddressOfEntryPoint),'0x1000'],capture_output=True,text=True,timeout=25)
        self.assertEqual(result.returncode,1)
        self.assertIn('UNSAFE_ENTRY_OR_TLS',result.stdout)
        self.assertNotIn('STOPPED_BEFORE_APPLICATION_ENTRY_NO_TLS_CALLBACKS',result.stdout)


@unittest.skipUnless(os.environ.get('NONAG_FIXTURE_ROOT'),'Local vendor fixtures not configured')
class RealCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.fixtures=pathlib.Path(os.environ['NONAG_FIXTURE_ROOT'])
        self.reference=json.loads((ROOT/'scripts/compatibility-reference.json').read_text())

    def test_reviewed_originals_and_real_dialog_resources(self):
        for version in ('18.3.0.34','18.4.0.48','19.0.0.94'):
            with self.subTest(version=version):
                directory=self.fixtures/version
                result=compatibility.check(directory/'ProcessLasso.exe',directory/'pl_rsrc_english.dll',DLL,BUILD,self.reference)
                self.assertEqual(result['Status'],'pass')

    def test_changed_dialog_argument_and_callback_require_review(self):
        directory=self.fixtures/'18.4.0.48'
        source=directory/'ProcessLasso.exe'
        resource=directory/'pl_rsrc_english.dll'
        patterns=[(bytes.fromhex('bac3000000'),bytes.fromhex('bac4000000')),
                  (bytes.fromhex('c744244800000000'),bytes.fromhex('c744244c00000000'))]
        for before,after in patterns:
            data=source.read_bytes()
            self.assertIn(before,data)
            with tempfile.TemporaryDirectory() as folder:
                changed=pathlib.Path(folder)/'ProcessLasso.exe'
                changed.write_bytes(data.replace(before,after))
                with self.assertRaises(Inconclusive):
                    compatibility.check(changed,resource,DLL,BUILD,self.reference)

    def test_resource_role_change_requires_review(self):
        directory=self.fixtures/'18.4.0.48'
        source=directory/'pl_rsrc_english.dll'
        pe=pefile.PE(data=source.read_bytes())
        block=next(name for kind in pe.DIRECTORY_ENTRY_RESOURCE.entries if kind.id==6 for name in kind.directory.entries if name.id==0x291//16+1)
        record=block.directory.entries[0].data.struct
        data=bytearray(source.read_bytes())
        offset=pe.get_offset_from_rva(record.OffsetToData)
        for index in range(0x291%16+1):
            length=struct.unpack_from('<H',data,offset)[0]
            offset+=2
            if index==0x291%16:
                self.assertGreater(length,0)
                data[offset:offset+2]=b'X\x00'
            offset+=length*2
        with tempfile.TemporaryDirectory() as folder:
            resource=pathlib.Path(folder)/'pl_rsrc_english.dll'
            resource.write_bytes(data)
            with self.assertRaisesRegex(Inconclusive,'structure-or-resources'):
                compatibility.check(directory/'ProcessLasso.exe',resource,DLL,BUILD,self.reference)

    def test_changed_switch_target_requires_review(self):
        directory=self.fixtures/'19.0.0.94'
        source=directory/'ProcessLasso.exe'
        data=bytearray(source.read_bytes())
        pe=pefile.PE(data=data)
        offset=pe.get_offset_from_rva(0xd818)
        struct.pack_into('<I', data, offset, 0xcbf0)
        with tempfile.TemporaryDirectory() as folder:
            changed=pathlib.Path(folder)/'ProcessLasso.exe'
            changed.write_bytes(data)
            with self.assertRaisesRegex(Inconclusive, 'structure-or-resources'):
                compatibility.check(changed,directory/'pl_rsrc_english.dll',DLL,BUILD,self.reference)

    def test_changed_reminder_body_requires_review(self):
        directory=self.fixtures/'19.0.0.94'
        source=directory/'ProcessLasso.exe'
        data=source.read_bytes()
        body=bytes.fromhex('41b891020000')
        self.assertIn(body, data)
        with tempfile.TemporaryDirectory() as folder:
            changed=pathlib.Path(folder)/'ProcessLasso.exe'
            changed.write_bytes(data.replace(body, bytes.fromhex('41b8ce010000'), 1))
            with self.assertRaises(Inconclusive):
                compatibility.check(changed,directory/'pl_rsrc_english.dll',DLL,BUILD,self.reference)


if __name__=='__main__': unittest.main()
