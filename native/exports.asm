option casemap:none
EXTERN ResolveVersionExport:PROC
EXTERN VersionFunctions:QWORD
.code

; Preserve the x64 argument registers and original stack for undocumented exports.
FORWARD MACRO name, index
PUBLIC name
name PROC FRAME
    sub rsp, 0C8h
    .allocstack 0C8h
    .endprolog
    mov [rsp+20h], rax
    mov [rsp+28h], rcx
    mov [rsp+30h], rdx
    mov [rsp+38h], r8
    mov [rsp+40h], r9
    mov [rsp+48h], r10
    mov [rsp+50h], r11
    movdqu [rsp+60h], xmm0
    movdqu [rsp+70h], xmm1
    movdqu [rsp+80h], xmm2
    movdqu [rsp+90h], xmm3
    movdqu [rsp+0A0h], xmm4
    movdqu [rsp+0B0h], xmm5
    call ResolveVersionExport
    movdqu xmm0, [rsp+60h]
    movdqu xmm1, [rsp+70h]
    movdqu xmm2, [rsp+80h]
    movdqu xmm3, [rsp+90h]
    movdqu xmm4, [rsp+0A0h]
    movdqu xmm5, [rsp+0B0h]
    mov rax, [rsp+20h]
    mov rcx, [rsp+28h]
    mov rdx, [rsp+30h]
    mov r8, [rsp+38h]
    mov r9, [rsp+40h]
    mov r10, [rsp+48h]
    mov r11, [rsp+50h]
    add rsp, 0C8h
    jmp QWORD PTR [VersionFunctions+index*8]
name ENDP
ENDM

FORWARD Forward0, 0
FORWARD Forward1, 1
FORWARD Forward2, 2
FORWARD Forward3, 3
FORWARD Forward4, 4
FORWARD Forward5, 5
FORWARD Forward6, 6
FORWARD Forward7, 7
FORWARD Forward8, 8
FORWARD Forward9, 9
FORWARD Forward10, 10
FORWARD Forward11, 11
FORWARD Forward12, 12
FORWARD Forward13, 13
FORWARD Forward14, 14
FORWARD Forward15, 15
FORWARD Forward16, 16
END
