import bisect
import hashlib
import json
import re
import struct

import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_64, CS_GRP_CALL, CS_GRP_JUMP
from capstone.x86 import X86_OP_IMM, X86_OP_MEM, X86_OP_REG, X86_REG_RIP, X86_REG_RSP, X86_REG_RBP

MAX_SIZE = 32 * 1024 * 1024


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

    def function(self, address):
        rva = address - self.base
        index = bisect.bisect_right(self.starts, rva) - 1
        if index < 0 or rva >= self.functions[index][1]:
            raise Inconclusive('function-range-missing')
        return self.functions[index]

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

    def normalize(self, instructions):
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
                        value = alias('call', op.imm)
                    elif ins.group(CS_GRP_JUMP):
                        value = ['branch', positions[op.imm]] if op.imm in positions else alias('exit', op.imm)
                    else:
                        value = ['imm', op.imm]
                elif op.type == X86_OP_MEM:
                    mem = op.mem
                    if mem.base == X86_REG_RIP:
                        address = ins.address + ins.size + mem.disp
                        if address == self.base:
                            value = ['image-base']
                        elif address in self.imports:
                            value = ['import', self.imports[address]]
                        elif self.executable(address):
                            value = alias('code', address)
                        else:
                            text = self.text_at(address)
                            value = ['text', text] if text else alias('data', address)
                    elif mem.base in (X86_REG_RSP, X86_REG_RBP):
                        value = ['stack', ins.reg_name(mem.base), mem.disp, ins.reg_name(mem.index), mem.scale]
                    else:
                        value = ['mem', ins.reg_name(mem.segment), ins.reg_name(mem.base), ins.reg_name(mem.index), mem.scale, mem.disp]
                else:
                    raise Inconclusive('unknown-operand')
                operands.append([op.size, value])
            tokens.append([ins.mnemonic, operands])
        return tokens


