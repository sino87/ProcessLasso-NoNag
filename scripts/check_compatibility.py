import argparse
import hashlib
import importlib.metadata
import json
import ntpath
import os
import pathlib
import platform
import shutil
import struct
import subprocess
import tempfile

import pefile
import capstone
from capstone.x86 import X86_OP_IMM, X86_OP_MEM, X86_REG_RIP
from pe_image import Image, Inconclusive, canonical, digest, resource_roles, write_json


def imported(image, instruction):
    if instruction.mnemonic not in ('call', 'jmp') or not instruction.operands:
        return None
    operand = instruction.operands[0]
    if operand.type == X86_OP_MEM and operand.mem.base == X86_REG_RIP:
        return image.imports.get(instruction.address + instruction.size + operand.mem.disp)
    return None


def argument(instructions, index, names, address=False):
    for instruction in reversed(instructions[max(0, index-24):index]):
        if instruction.mnemonic == 'call':
            break
        if not {instruction.reg_name(r) for r in instruction.regs_access()[1]}.intersection(names):
            continue
        if instruction.mnemonic == 'mov' and instruction.operands[1].type == X86_OP_IMM:
            return instruction.operands[1].imm
        if address and instruction.mnemonic == 'lea' and instruction.operands[1].type == X86_OP_MEM and instruction.operands[1].mem.base == X86_REG_RIP:
            return instruction.address + instruction.size + instruction.operands[1].mem.disp
        break
    raise Inconclusive('dialog-argument-unresolved')


def fingerprint(image, instructions):
    return digest(canonical(image.normalize(instructions)))


def structure(image, resources):
    dialogs = []
    decoded = {}
    for bounds in image.functions:
        start, end = bounds
        instructions = list(image.md.disasm(image.pe.get_data(start, end-start), image.base+start))
        decoded[bounds] = instructions
        for index, instruction in enumerate(instructions):
            if imported(image, instruction) != 'DialogBoxParamW':
                continue
            try:
                template = argument(instructions, index, {'rdx', 'edx', 'dx', 'dl'})
            except Inconclusive:
                continue
            if template in (0xc3, 0x13bf):
                callback = argument(instructions, index, {'r9', 'r9d'}, address=True)
                callback_bounds = image.function(callback)
                callback_instructions = list(image.md.disasm(image.pe.get_data(callback_bounds[0],callback_bounds[1]-callback_bounds[0]),image.base+callback_bounds[0]))
                if callback_instructions[0].address != callback or not image.executable(callback):
                    raise Inconclusive('dialog-callback-unresolved')
                dialogs.append((template, bounds, index, fingerprint(image, callback_instructions)))
    reminders = [d for d in dialogs if d[0] == 0xc3]
    offers = [d for d in dialogs if d[0] == 0x13bf]
    if len(reminders) != 3 or len(offers) != 2:
        raise Inconclusive('dialog-route-count-changed')
    direct_targets = [ins.operands[0].imm for instructions in decoded.values() for ins in instructions
                      if ins.mnemonic == 'call' and ins.operands[0].type == X86_OP_IMM]
    helpers = [d for d in reminders if direct_targets.count(image.base+d[1][0]) == 18]
    if len(helpers) != 1:
        raise Inconclusive('reminder-helper-unresolved')
    helper = helpers[0][1]
    callers = []
    for instructions in decoded.values():
        for index, instruction in enumerate(instructions):
            if instruction.mnemonic == 'call' and instruction.operands[0].type == X86_OP_IMM and instruction.operands[0].imm == image.base+helper[0]:
                body = argument(instructions, index, {'r8', 'r8d', 'r8w', 'r8b'})
                if body not in (0x291, 0x1ce):
                    raise Inconclusive('reminder-body-role-changed')
                callers.append({'Body': body, 'Context': fingerprint(image, instructions[max(0,index-7):index+3])})
    if sum(c['Body'] == 0x291 for c in callers) != 3 or sum(c['Body'] == 0x1ce for c in callers) != 15:
        raise Inconclusive('reminder-caller-count-changed')
    resource_pe = pefile.PE(data=resources.read_bytes())
    if resource_pe.FILE_HEADER.Machine != 0x8664:
        raise Inconclusive('resources-not-x64')
    dialog_ids = {name.id for kind in resource_pe.DIRECTORY_ENTRY_RESOURCE.entries if kind.id == 5 for name in kind.directory.entries}
    if not {0xc3, 0xc9, 0x13bf}.issubset(dialog_ids):
        raise Inconclusive('required-dialog-resource-missing')
    return {
        'Resources': resource_roles(resources, image.version),
        'ReminderHelper': fingerprint(image, decoded[helper]),
        'ReminderCallback': helpers[0][3],
        'OtherReminderRoutes': sorted(fingerprint(image,decoded[b][max(0,i-7):i+3])+callback for _,b,i,callback in reminders if b != helper),
        'OfferCallbacks': sorted(d[3] for d in offers),
        'OfferRoutes': sorted(fingerprint(image, decoded[b][max(0,i-7):i+3]) for _,b,i,_ in offers),
        'ReminderCallers': sorted(callers, key=lambda c:(c['Body'],c['Context'])),
    }


def verify_imports(image, dll):
    exports = pefile.PE(data=dll.read_bytes())
    if exports.FILE_HEADER.Machine != 0x8664:
        raise Inconclusive('proxy-not-x64')
    names = {x.name for x in exports.DIRECTORY_ENTRY_EXPORT.symbols}
    ordinals = {x.ordinal for x in exports.DIRECTORY_ENTRY_EXPORT.symbols}
    slots = []
    for descriptor in image.pe.DIRECTORY_ENTRY_IMPORT:
        if descriptor.dll.lower() == b'version.dll':
            for symbol in descriptor.imports:
                if (symbol.name and symbol.name not in names) or (not symbol.name and symbol.ordinal not in ordinals):
                    raise Inconclusive('required-version-export-missing')
                slots.append(symbol.address-image.base)
    dialogs = [symbol.address-image.base for descriptor in image.pe.DIRECTORY_ENTRY_IMPORT if descriptor.dll.lower() == b'user32.dll'
               for symbol in descriptor.imports if symbol.name == b'DialogBoxParamW']
    if not slots or len(dialogs) != 1:
        raise Inconclusive('required-import-route-changed')
    if getattr(image.pe, 'DIRECTORY_ENTRY_DELAY_IMPORT', []):
        raise Inconclusive('delay-imports-require-review')
    tls = getattr(image.pe, 'DIRECTORY_ENTRY_TLS', None)
    if tls and tls.struct.AddressOfCallBacks:
        rva = tls.struct.AddressOfCallBacks-image.base
        if rva < 0 or rva > image.pe.OPTIONAL_HEADER.SizeOfImage-8 or struct.unpack('<Q', image.pe.get_data(rva,8))[0]:
            raise Inconclusive('application-tls-callbacks-require-review')
    return dialogs+slots


def loader_check(exe, dll, image, slots, build):
    probe = build/'tests/native/Release/loader_probe.exe'
    with tempfile.TemporaryDirectory(prefix='nonag-loader-') as folder:
        directory = pathlib.Path(folder)
        target = directory/'ProcessLasso.exe'
        shutil.copyfile(exe, target)
        shutil.copyfile(dll, directory/'version.dll')
        result = subprocess.run([str(probe),str(target),hex(image.pe.OPTIONAL_HEADER.AddressOfEntryPoint),*[hex(s) for s in slots]], capture_output=True, text=True, timeout=25)
        if result.returncode or 'STOPPED_BEFORE_APPLICATION_ENTRY_NO_TLS_CALLBACKS' not in result.stdout:
            raise Inconclusive('loader-or-hook-not-confirmed')
        expected = ntpath.normcase(str((directory/'version.dll').resolve()))
        lines = [line.split('module=',1)[1] for line in result.stdout.splitlines() if line.startswith('IMPORT_SLOT')]
        if len(lines) != len(slots) or any(ntpath.normcase(ntpath.normpath(line).removeprefix('\\\\?\\')) != expected for line in lines):
            raise Inconclusive('import-not-owned-by-selected-proxy')


def check(exe, resources, dll, build, reference):
    image = Image(exe)
    slots = verify_imports(image, dll)
    actual = structure(image, resources)
    if actual not in [entry['Structure'] for entry in reference['References']]:
        raise Inconclusive('dialog-structure-or-resources-changed')
    loader_check(exe, dll, image, slots, build)
    runner = pathlib.Path(__file__).parents[1]/'tests/Test-Native.ps1'
    result = subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(runner),'-BuildDirectory',str(build),'-DllPath',str(dll),'-ResourcePaths',str(resources)], capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise Inconclusive('native-dialog-or-forwarding-test-failed')
    return {'Status':'pass','Reason':'Selected DLL imports, dialog structures, loader hook and native behavior verified.'}


def main():
    parser = argparse.ArgumentParser()
    for option in ('exe','resources','dll','build','output'):
        parser.add_argument('--'+option, type=pathlib.Path, required=True)
    parser.add_argument('--reference', type=pathlib.Path, default=pathlib.Path(__file__).with_name('compatibility-reference.json'))
    parser.add_argument('--record-reference', action='store_true')
    parser.add_argument('--expected-source-hash')
    args = parser.parse_args()
    if args.record_reference:
        image = Image(args.exe)
        if args.expected_source_hash != digest(image.data):
            raise ValueError('Reference recording requires the reviewed original SHA-256')
        reference = json.loads(args.reference.read_text()) if args.reference.exists() else {'Schema':1,'References':[]}
        entry = {'Version':image.version,'SourceHash':digest(image.data),'Structure':structure(image,args.resources)}
        reference['References'] = [r for r in reference['References'] if r['SourceHash'] != entry['SourceHash']] + [entry]
        write_json(args.reference, reference)
        return 0
    try:
        result = check(args.exe,args.resources,args.dll,args.build,json.loads(args.reference.read_text()))
    except Inconclusive as error:
        result = {'Status':'review','Reason':str(error)}
    except Exception as error:
        result = {'Status':'error','Reason':f'Compatibility check failed ({type(error).__name__}).'}
    result.update({'ExecutableHash':digest(args.exe.read_bytes()),'DllHash':digest(args.dll.read_bytes()),
                   'CheckerRevision':hashlib.sha256(pathlib.Path(__file__).read_bytes()+pathlib.Path(__file__).with_name('pe_image.py').read_bytes()+args.reference.read_bytes()).hexdigest(),
                   'SourceRevision':os.environ.get('GITHUB_SHA','local'),
                   'Environment':{'Windows':platform.platform(),'Python':platform.python_version(),'pefile':pefile.__version__,
                                  'capstone':importlib.metadata.version('capstone'),'CapstoneBinding':capstone.__version__}})
    write_json(args.output, result)
    print(json.dumps(result))
    return 1 if result['Status']=='error' else 0


if __name__ == '__main__':
    raise SystemExit(main())
