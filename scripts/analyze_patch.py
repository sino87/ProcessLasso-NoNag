import argparse
import bisect
import hashlib
import json
import pathlib
import re
import struct

import pefile
import capstone
from capstone import Cs, CS_ARCH_X86, CS_MODE_64, CS_GRP_CALL, CS_GRP_JUMP, CS_GRP_RET
from capstone.x86 import X86_OP_IMM, X86_OP_MEM, X86_OP_REG, X86_REG_RIP, X86_REG_RSP, X86_REG_RBP
from patch_profiles import validate_profile, validate_analysis

SCHEMA = 1
MAX_SIZE = 32 * 1024 * 1024
ROUTES = ('window-restore-nag', 'startup-offer', 'startup-nag')


class Inconclusive(Exception):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def read_bytes(path):
    if path.stat().st_size > MAX_SIZE:
        raise ValueError('Input exceeds size limit')
    return path.read_bytes()


def resource_roles(path,version):
    pe = pefile.PE(data=read_bytes(path))
    info=pe.VS_FIXEDFILEINFO[0]
    actual='.'.join(map(str,(info.FileVersionMS>>16,info.FileVersionMS&65535,info.FileVersionLS>>16,info.FileVersionLS&65535)))
    if actual!=version: raise Inconclusive('resource-version-mismatch')
    roles = {}
    for kind in pe.DIRECTORY_ENTRY_RESOURCE.entries:
        for name in kind.directory.entries:
            if (kind.id, name.id) not in ((6, 0x291 // 16 + 1), (5, 0x13BF)):
                continue
            entries = []
            for lang in name.directory.entries:
                record = lang.data.struct
                raw = pe.get_data(record.OffsetToData, record.Size)
                if kind.id == 6:
                    position = 0
                    for index in range(16):
                        length = struct.unpack_from('<H', raw, position)[0]
                        position += 2
                        text = raw[position:position + 2 * length].decode('utf-16-le')
                        position += 2 * length
                        if (name.id - 1) * 16 + index == 0x291:
                            entries.append(text)
                else:
                    entries.extend(m.group().decode('utf-16-le') for m in re.finditer(rb'(?:[\x20-\x7e]\x00){4,}', raw))
            roles['reminder' if kind.id == 6 else 'offer'] = digest(canonical(sorted(set(entries))))
    if set(roles) != {'reminder', 'offer'}:
        raise Inconclusive('resource-roles-missing')
    return roles


class Image:
    def __init__(self, path):
        self.data = read_bytes(path)
        self.pe = pefile.PE(data=self.data)
        if self.pe.FILE_HEADER.Machine != 0x8664 or self.pe.OPTIONAL_HEADER.Magic != 0x20B:
            raise ValueError('Expected x64 PE')
        self.base = self.pe.OPTIONAL_HEADER.ImageBase
        self.md = Cs(CS_ARCH_X86, CS_MODE_64)
        self.md.detail = True
        self.functions = [(e.struct.BeginAddress, e.struct.EndAddress) for e in self.pe.DIRECTORY_ENTRY_EXCEPTION]
        self.starts = [s for s, _ in self.functions]
        if self.functions != sorted(self.functions) or any(e <= s or e - s > MAX_SIZE for s, e in self.functions):
            raise ValueError('Invalid runtime-function ranges')
        self.imports = {i.address: i.name.decode() if i.name else str(i.ordinal)
                        for d in self.pe.DIRECTORY_ENTRY_IMPORT for i in d.imports}
        info = self.pe.VS_FIXEDFILEINFO[0]
        self.version = '.'.join(map(str, (info.FileVersionMS >> 16, info.FileVersionMS & 65535,
                                         info.FileVersionLS >> 16, info.FileVersionLS & 65535)))
        self.decoded = {}
        self.helpers = {}
        self.tables = {}

    def function(self, address):
        rva = address - self.base
        index = bisect.bisect_right(self.starts, rva) - 1
        if index < 0 or rva >= self.functions[index][1]:
            raise Inconclusive('function-range-missing')
        return self.functions[index]

    def instructions(self, bounds):
        if bounds not in self.decoded:
            start, end = bounds
            pending = [self.base + start]
            decoded = {}
            covered = set()
            while pending:
                address = pending.pop()
                while self.base + start <= address < self.base + end and address not in decoded:
                    instruction = next(self.md.disasm(self.pe.get_data(address-self.base, min(15,self.base+end-address)), address, count=1), None)
                    if instruction is None or any(b in covered for b in range(address,address+instruction.size)):
                        raise Inconclusive('incomplete-function-decode')
                    decoded[address] = instruction
                    covered.update(range(address,address+instruction.size))
                    if len(decoded) > 30000:
                        raise ValueError('Function instruction limit exceeded')
                    if instruction.group(CS_GRP_JUMP):
                        if instruction.operands[0].type == X86_OP_IMM:
                            target = instruction.operands[0].imm
                            if self.base+start <= target < self.base+end:
                                pending.append(target)
                        elif instruction.mnemonic == 'jmp':
                            resolved=False
                            previous = [decoded[a] for a in sorted(decoded) if a < address][-5:]
                            if (len(previous) == 5 and previous[0].mnemonic == 'cmp' and previous[1].mnemonic == 'ja'
                                    and previous[2].mnemonic == 'lea' and previous[3].mnemonic == 'mov'
                                    and previous[4].mnemonic == 'add'):
                                limit = previous[0].operands[-1]
                                pointer = previous[2].operands[-1]
                                indexed = previous[3].operands[-1]
                                if (limit.type == X86_OP_IMM and 0 <= limit.imm < 64 and pointer.type == X86_OP_MEM
                                        and pointer.mem.base == X86_REG_RIP and previous[2].address+previous[2].size+pointer.mem.disp == self.base
                                        and indexed.type == X86_OP_MEM and indexed.mem.scale == 4
                                        and indexed.mem.base == previous[2].operands[0].reg):
                                    table = self.pe.get_data(indexed.mem.disp, 4*(limit.imm+1))
                                    targets = [self.base+x[0] for x in struct.iter_unpack('<I',table)]
                                    if len(targets) != limit.imm+1 or any(not self.base+start <= t < self.base+end for t in targets):
                                        raise Inconclusive('invalid-switch-table')
                                    self.tables[previous[3].address] = targets
                                    pending.extend(targets)
                                    resolved=True
                            operand=instruction.operands[0]
                            if operand.type==X86_OP_MEM and operand.mem.base==X86_REG_RIP:
                                resolved=instruction.address+instruction.size+operand.mem.disp in self.imports
                            if not resolved: raise Inconclusive('unresolved-indirect-branch')
                        if instruction.mnemonic == 'jmp':
                            break
                    if instruction.group(CS_GRP_RET) or instruction.mnemonic in ('int3','ud2'):
                        break
                    address += instruction.size
            instructions = [decoded[a] for a in sorted(decoded)]
            self.decoded[bounds] = instructions
        return self.decoded[bounds]

    def executable(self, address):
        section = self.pe.get_section_by_rva(address - self.base)
        return section is not None and bool(section.Characteristics & 0x20000000)

    def text_at(self, address):
        raw = self.pe.get_data(address - self.base, 256)
        for encoding in ('utf-16-le', 'ascii'):
            try:
                value = raw[:len(raw) // 2 * 2].decode(encoding).split('\0')[0] if encoding == 'utf-16-le' else raw.split(b'\0')[0].decode(encoding)
                if 6 <= len(value) <= 100 and all(32 <= ord(c) < 127 for c in value):
                    return digest(value.encode())
            except UnicodeError:
                pass
        return None

    def helper(self, address):
        if address not in self.helpers:
            instructions = self.instructions(self.function(address))
            if instructions[0].address != address or len(instructions) > 2048:
                raise Inconclusive('unsupported-helper')
            self.helpers[address] = digest(canonical(self.normalize(instructions, False)))
        return self.helpers[address]

    def normalize(self, instructions, helpers=True):
        positions = {ins.address: i for i, ins in enumerate(instructions)}
        aliases = {}

        def alias(kind, value):
            table = aliases.setdefault(kind, {})
            if value not in table:
                table[value] = len(table)
            return [kind, table[value]]

        tokens = []
        for ins in instructions:
            operands = []
            for op in ins.operands:
                if op.type == X86_OP_REG:
                    value = ['reg', ins.reg_name(op.reg)]
                elif op.type == X86_OP_IMM:
                    if ins.group(CS_GRP_CALL):
                        value = ['call', self.helper(op.imm)] if helpers else alias('call', op.imm)
                    elif ins.group(CS_GRP_JUMP):
                        value = ['branch', positions[op.imm]] if op.imm in positions else alias('exit', op.imm)
                    else:
                        value = ['imm', op.imm]
                elif op.type == X86_OP_MEM:
                    mem = op.mem
                    if ins.address in self.tables:
                        if any(t not in positions for t in self.tables[ins.address]):
                            raise Inconclusive('switch-target-outside-region')
                        value = ['switch-table', [positions[t] for t in self.tables[ins.address]]]
                    elif mem.base == X86_REG_RIP:
                        address = ins.address + ins.size + mem.disp
                        if address == self.base:
                            value = ['image-base']
                        elif address in self.imports:
                            value = ['import', self.imports[address]]
                        elif self.executable(address):
                            value = ['code', self.helper(address)] if helpers else alias('code', address)
                        else:
                            text = self.text_at(address)
                            value = ['text', text] if text else alias('data', address)
                    elif mem.base in (X86_REG_RSP, X86_REG_RBP):
                        value = ['stack', ins.reg_name(mem.base), -1 if mem.disp < 0 else 1,
                                 alias('slot', (mem.base, mem.disp)), ins.reg_name(mem.index), mem.scale]
                    else:
                        value = ['mem', ins.reg_name(mem.segment), ins.reg_name(mem.base), ins.reg_name(mem.index), mem.scale, mem.disp]
                else:
                    raise Inconclusive('unknown-operand')
                operands.append([op.size, value])
            tokens.append([ins.mnemonic, operands])
        return tokens

    def window(self, ins, index):
        branch = ins[index]
        if branch.mnemonic not in ('je', 'jne') or branch.size not in (2, 6) or branch.operands[0].type != X86_OP_IMM:
            raise Inconclusive('unsupported-branch')
        target = branch.operands[0].imm
        addresses = {i.address: n for n, i in enumerate(ins)}
        if index < 2 or target not in addresses or not 0 < target - branch.address <= 512:
            raise Inconclusive('invalid-branch-target')
        end = addresses[target]
        selected = ins[index-2:min(len(ins), end+3)]
        resource_ids = sorted({op.imm for i in ins[index+1:end] for op in i.operands
                               if i.mnemonic == 'mov' and op.type == X86_OP_IMM and op.imm in (0x291, 0x13BF)})
        if not resource_ids:
            raise Inconclusive('display-reference-missing')
        if not all(self.executable(i.address) for i in selected):
            raise Inconclusive('nonexecutable-site')
        return selected, resource_ids


def make_template(image, resources, profile):
    if digest(image.data) != profile['OriginalHash'] or image.version != profile['Version'] or not profile['VmValidated']:
        raise ValueError('Template source must be a registered VM-validated original')
    routes = []
    for patch in profile['Patches']:
        address = image.base + image.pe.get_rva_from_offset(patch['Offset'])
        instructions = image.instructions(image.function(address))
        index = next(i for i, ins in enumerate(instructions) if ins.address == address)
        selected, roles = image.window(instructions, index)
        if bytes(instructions[index].bytes).hex() != patch['Before']:
            raise ValueError('Baseline preimage mismatch')
        routes.append({'Name': patch['Name'], 'Resources': roles, 'Tokens': image.normalize(selected)})
    return {'Schema': SCHEMA, 'Version': image.version, 'OriginalHash': digest(image.data),
            'Resources': resource_roles(resources,image.version), 'Routes': routes}


def apply_candidate(image, sites):
    output = bytearray(image.data)
    patches, evidence = [], []
    predicates=set()
    for name, ins in sites:
        function=image.instructions(image.function(ins.address))
        index=next(i for i,x in enumerate(function) if x.address==ins.address)
        predicate=function[index-2]
        if not predicate.group(CS_GRP_CALL) or predicate.operands[0].type != X86_OP_IMM:
            raise Inconclusive('shared-predicate-missing')
        predicates.add(predicate.operands[0].imm)
        target = ins.operands[0].imm
        before = bytes(ins.bytes)
        after = bytes((0xEB, before[1])) if len(before) == 2 else b'\xe9' + struct.pack('<i', target - ins.address - 5) + b'\x90'
        decoded = list(image.md.disasm(after, ins.address))
        if (decoded[0].mnemonic != 'jmp' or decoded[0].operands[0].imm != target or
                any(i.mnemonic != 'nop' for i in decoded[1:]) or sum(i.size for i in decoded) != len(before)):
            raise ValueError('Invalid replacement')
        offset = image.pe.get_offset_from_rva(ins.address-image.base)
        if image.data[offset:offset+len(before)] != before:
            raise ValueError('Preimage mismatch')
        patches.append({'Name': name, 'Offset': offset, 'Before': before.hex(), 'After': after.hex()})
        evidence.append({'Name': name, 'Rva': ins.address-image.base, 'TargetRva': target-image.base,
                         'Before': before.hex(), 'After': after.hex(), 'PredicateRva': predicate.operands[0].imm-image.base,
                         'BeforeInstruction': f'{ins.mnemonic} {ins.op_str}',
                         'AfterInstructions': [f'{i.mnemonic} {i.op_str}' for i in decoded]})
    if len(predicates)!=1: raise Inconclusive('shared-predicate-changed')
    patches.sort(key=lambda p: p['Offset'])
    for left, right in zip(patches, patches[1:]):
        if left['Offset'] + len(bytes.fromhex(left['Before'])) > right['Offset']:
            raise Inconclusive('overlapping-sites')
    expected = set()
    for patch in patches:
        before, after = bytes.fromhex(patch['Before']), bytes.fromhex(patch['After'])
        offset = patch['Offset']
        output[offset:offset+len(before)] = after
        expected.update(offset+i for i,(a,b) in enumerate(zip(before,after)) if a != b)
    changed = {i for i,(a,b) in enumerate(zip(image.data,output)) if a != b}
    if changed != expected or len(changed) != 6 or len(output) != len(image.data):
        raise ValueError('Unexpected changes')
    for patch in patches:
        offset = patch['Offset']
        output[offset:offset+len(bytes.fromhex(patch['Before']))] = bytes.fromhex(patch['Before'])
    if bytes(output) != image.data:
        raise ValueError('Reversal mismatch')
    for patch in patches:
        offset = patch['Offset']
        output[offset:offset+len(bytes.fromhex(patch['After']))] = bytes.fromhex(patch['After'])
    return validate_profile({'Version': image.version, 'VmValidated': False, 'OriginalHash': digest(image.data),
                             'PatchedHash': digest(output), 'Patches': patches}), evidence


def analyze(image, resources, templates):
    roles = resource_roles(resources,image.version)
    matches = {name: {} for name in ROUTES}
    valid = [t for t in templates if t['Schema'] == SCHEMA and t['Resources'] == roles]
    if not valid:
        raise Inconclusive('resource-roles-changed')
    reference = {name: [r for t in valid for r in t['Routes'] if r['Name'] == name] for name in ROUTES}
    for bounds in image.functions:
        try:
            ins = image.instructions(bounds)
        except Inconclusive:
            continue
        for index, branch in enumerate(ins):
            if branch.mnemonic not in ('je', 'jne'):
                continue
            try:
                selected, ids = image.window(ins, index)
                tokens = image.normalize(selected)
            except Inconclusive:
                continue
            for name in ROUTES:
                if any(r['Resources'] == ids and r['Tokens'] == tokens for r in reference[name]):
                    matches[name][branch.address] = branch
    counts = {name: len(found) for name, found in matches.items()}
    if any(count != 1 for count in counts.values()):
        raise Inconclusive('route-matches:' + json.dumps(counts, sort_keys=True))
    profile, evidence = apply_candidate(image, [(n,next(iter(matches[n].values()))) for n in ROUTES])
    return {'Status': 'candidate', 'Reason': 'Three unique reviewed route structures matched; VM validation required.',
            'Profile': profile, 'Evidence': evidence, 'Templates': sorted(t['OriginalHash'] for t in valid)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=('template', 'analyze'))
    parser.add_argument('--exe', type=pathlib.Path, required=True)
    parser.add_argument('--resources', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--profiles', type=pathlib.Path, default=pathlib.Path(__file__).parents[1]/'src/profiles.json')
    parser.add_argument('--templates', type=pathlib.Path, default=pathlib.Path(__file__).parent/'templates')
    args = parser.parse_args()
    try:
        image = Image(args.exe)
        if args.mode == 'template':
            profile = next(p for p in json.loads(args.profiles.read_text()) if p['OriginalHash'] == digest(image.data))
            result = make_template(image, args.resources, profile)
        else:
            templates = [json.loads(p.read_text()) for p in sorted(args.templates.glob('*.json'))]
            result = analyze(image, args.resources, templates)
    except Inconclusive as error:
        result = {'Status': 'inconclusive', 'Reason': str(error)}
    except Exception:
        result = {'Status': 'error', 'Reason': 'Analyzer input or processing error.'}
    if args.mode=='analyze':
        source=pathlib.Path(__file__)
        result['AnalyzerHash']=digest(source.read_bytes()+source.with_name('patch_profiles.py').read_bytes()
                                      + canonical([capstone.__version__,pefile.__version__])
                                      + b''.join(p.read_bytes() for p in sorted(args.templates.glob('*.json'))))
        validate_analysis(result)
    write_json(args.output, result)
    print(result.get('Status', 'template'))
    return 1 if result.get('Status') == 'error' else 0


if __name__ == '__main__':
    raise SystemExit(main())
