import re
import struct

ROUTES = {'window-restore-nag', 'startup-offer', 'startup-nag'}


def validate_profile(profile):
    if set(profile) != {'Version','VmValidated','OriginalHash','PatchedHash','Patches'}:
        raise ValueError('Invalid profile fields')
    if not re.fullmatch(r'\d+\.\d+\.\d+\.\d+', profile['Version']) or type(profile['VmValidated']) is not bool:
        raise ValueError('Invalid version or validation flag')
    if any(not re.fullmatch('[a-f0-9]{64}',profile[k]) for k in ('OriginalHash','PatchedHash')) or profile['OriginalHash'] == profile['PatchedHash']:
        raise ValueError('Invalid profile hashes')
    patches = profile['Patches']
    if len(patches) != 3 or {p['Name'] for p in patches} != ROUTES:
        raise ValueError('Expected three routes')
    end = 0
    for patch in patches:
        if set(patch) != {'Name','Offset','Before','After'} or type(patch['Offset']) is not int or not end <= patch['Offset'] <= 0x7FFFFFF9:
            raise ValueError('Invalid patch fields or overlap')
        if not re.fullmatch(r'(?:74|75)[a-f0-9]{2}|0f8[45][a-f0-9]{8}',patch['Before']):
            raise ValueError('Unsupported branch form')
        before, after = bytes.fromhex(patch['Before']),bytes.fromhex(patch['After'])
        expected = b'\xeb'+before[1:] if len(before)==2 else b'\xe9'+struct.pack('<i',struct.unpack('<i',before[2:])[0]+1)+b'\x90'
        if after != expected:
            raise ValueError('Replacement must preserve target')
        end = patch['Offset']+len(before)
    return profile


def validate_analysis(analysis):
    status=analysis['Status']
    common={'Status','Reason','AnalyzerHash'}
    expected=common|{'Profile','Evidence','Templates'} if status=='candidate' else common
    if set(analysis)!=expected or status not in ('candidate','inconclusive','error'):
        raise ValueError('Invalid analysis fields')
    if not isinstance(analysis['Reason'],str) or len(analysis['Reason'])>512 or not re.fullmatch('[a-f0-9]{64}',analysis['AnalyzerHash']):
        raise ValueError('Invalid analysis metadata')
    if status!='candidate': return analysis
    profile=validate_profile(analysis['Profile'])
    if profile['VmValidated']: raise ValueError('Candidate cannot be VM-validated')
    evidence=analysis['Evidence']
    if len(evidence)!=3 or {e['Name'] for e in evidence}!=ROUTES: raise ValueError('Invalid evidence routes')
    predicates=set()
    for item in evidence:
        if set(item)!={'Name','Rva','TargetRva','Before','After','PredicateRva','BeforeInstruction','AfterInstructions'}:
            raise ValueError('Invalid evidence fields')
        for key in ('Rva','TargetRva','PredicateRva'):
            if type(item[key]) is not int or not 0<=item[key]<=0xFFFFFFFF: raise ValueError('Invalid evidence address')
        patch=next(p for p in profile['Patches'] if p['Name']==item['Name'])
        if item['Before']!=patch['Before'] or item['After']!=patch['After']: raise ValueError('Evidence differs from profile')
        before=bytes.fromhex(patch['Before'])
        displacement=struct.unpack('<b',before[1:])[0] if len(before)==2 else struct.unpack('<i',before[2:])[0]
        if item['TargetRva']!=item['Rva']+len(before)+displacement: raise ValueError('Invalid evidence target')
        if not re.fullmatch(r'j(?:e|ne) 0x[a-f0-9]+',item['BeforeInstruction']): raise ValueError('Invalid original instruction')
        instructions=item['AfterInstructions']
        if not isinstance(instructions,list) or not 1<=len(instructions)<=2 or not re.fullmatch(r'jmp 0x[a-f0-9]+',instructions[0]) or any(x.strip()!='nop' for x in instructions[1:]):
            raise ValueError('Invalid replacement instructions')
        predicates.add(item['PredicateRva'])
    if len(predicates)!=1: raise ValueError('Inconsistent shared predicate')
    if not isinstance(analysis['Templates'],list) or not 1<=len(analysis['Templates'])<=32 or any(not re.fullmatch('[a-f0-9]{64}',h) for h in analysis['Templates']):
        raise ValueError('Invalid template identities')
    return analysis
