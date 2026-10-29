#include <windows.h>
#include <cstdio>
#include <string>
#include <vector>
struct Module { void* base; std::wstring path; };
static std::wstring FilePath(HANDLE file) {
    wchar_t path[32768]{};
    const DWORD length=GetFinalPathNameByHandleW(file,path,ARRAYSIZE(path),FILE_NAME_NORMALIZED);
    return length && length<ARRAYSIZE(path) ? std::wstring(path,length) : L"<unavailable>";
}
template<class T> static bool Read(HANDLE process, const void* address, T& data) {
    SIZE_T bytes=0;
    return ReadProcessMemory(process,address,&data,sizeof(data),&bytes) && bytes==sizeof(data);
}
static bool BeforeTls(HANDLE process, BYTE* image, ULONGLONG entryRva) {
    IMAGE_DOS_HEADER dos{};
    IMAGE_NT_HEADERS64 nt{};
    if (!Read(process,image,dos) || dos.e_magic!=IMAGE_DOS_SIGNATURE || dos.e_lfanew<=0 || dos.e_lfanew>0x100000 ||
        !Read(process,image+dos.e_lfanew,nt) || nt.Signature!=IMAGE_NT_SIGNATURE ||
        nt.FileHeader.Machine!=IMAGE_FILE_MACHINE_AMD64 || nt.OptionalHeader.AddressOfEntryPoint!=entryRva ||
        entryRva>=nt.OptionalHeader.SizeOfImage) return false;
    const auto directory=nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_TLS];
    if (!directory.VirtualAddress) return true;
    if (directory.VirtualAddress>nt.OptionalHeader.SizeOfImage-sizeof(IMAGE_TLS_DIRECTORY64)) return false;
    IMAGE_TLS_DIRECTORY64 tls{};
    if (!Read(process,image+directory.VirtualAddress,tls)) return false;
    if (!tls.AddressOfCallBacks) return true;
    auto rva=tls.AddressOfCallBacks-nt.OptionalHeader.ImageBase;
    if (rva>=nt.OptionalHeader.SizeOfImage) rva=tls.AddressOfCallBacks-reinterpret_cast<ULONGLONG>(image);
    if (rva>nt.OptionalHeader.SizeOfImage-sizeof(ULONGLONG)) return false;
    ULONGLONG callback=1;
    return Read(process,image+rva,callback) && callback==0;
}
int wmain(int argc, wchar_t** argv) {
    if (argc<4) return 2;
    std::wstring target=argv[1], command=L"\""+target+L"\"";
    const auto entryRva=wcstoull(argv[2],nullptr,0);
    const auto directory=target.substr(0,target.find_last_of(L"\\/"));
    SetEnvironmentVariableW(L"__COMPAT_LAYER",L"RunAsInvoker");
    SetErrorMode(SEM_FAILCRITICALERRORS|SEM_NOGPFAULTERRORBOX|SEM_NOOPENFILEERRORBOX);
    STARTUPINFOW startup{sizeof(startup)};
    startup.dwFlags=STARTF_USESHOWWINDOW;
    startup.wShowWindow=SW_HIDE;
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(target.c_str(),command.data(),nullptr,nullptr,FALSE,DEBUG_ONLY_THIS_PROCESS|CREATE_SUSPENDED|CREATE_NO_WINDOW,
                        nullptr,directory.c_str(),&startup,&process)) return 3;
    HANDLE job=CreateJobObjectW(nullptr,nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limit{};
    limit.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!job || !SetInformationJobObject(job,JobObjectExtendedLimitInformation,&limit,sizeof(limit)) || !AssignProcessToJobObject(job,process.hProcess)) {
        TerminateProcess(process.hProcess,4);
        return 4;
    }
    ResumeThread(process.hThread);
    const ULONGLONG deadline=GetTickCount64()+15000;
    BYTE* image=nullptr;
    void* entry=nullptr;
    bool reached=false, exited=false, failed=false;
    std::vector<Module> modules;
    while (GetTickCount64()<deadline) {
        DEBUG_EVENT event{};
        if (!WaitForDebugEvent(&event,500)) continue;
        if (event.dwDebugEventCode==CREATE_PROCESS_DEBUG_EVENT) {
            image=static_cast<BYTE*>(event.u.CreateProcessInfo.lpBaseOfImage);
            entry=image+entryRva;
            BYTE trap=0xcc;
            DWORD protection=0, ignored=0;
            SIZE_T written=0;
            if (!BeforeTls(process.hProcess,image,entryRva) ||
                !VirtualProtectEx(process.hProcess,entry,1,PAGE_EXECUTE_READWRITE,&protection) ||
                !WriteProcessMemory(process.hProcess,entry,&trap,1,&written) || written!=1 ||
                !VirtualProtectEx(process.hProcess,entry,1,protection,&ignored) || !FlushInstructionCache(process.hProcess,entry,1)) {
                failed=true;
                std::puts("UNSAFE_ENTRY_OR_TLS");
                TerminateProcess(process.hProcess,5);
            }
            if (event.u.CreateProcessInfo.hFile) CloseHandle(event.u.CreateProcessInfo.hFile);
        } else if (event.dwDebugEventCode==LOAD_DLL_DEBUG_EVENT && event.u.LoadDll.hFile) {
            modules.push_back({event.u.LoadDll.lpBaseOfDll,FilePath(event.u.LoadDll.hFile)});
            CloseHandle(event.u.LoadDll.hFile);
        } else if (event.dwDebugEventCode==EXCEPTION_DEBUG_EVENT && !failed) {
            const auto& record=event.u.Exception.ExceptionRecord;
            if (record.ExceptionCode==EXCEPTION_BREAKPOINT && record.ExceptionAddress==entry) {
                for (int i=3;i<argc;++i) {
                    const auto rva=wcstoull(argv[i],nullptr,0);
                    void* function=nullptr;
                    MEMORY_BASIC_INFORMATION memory{};
                    bool found=false;
                    if (Read(process.hProcess,image+rva,function) && VirtualQueryEx(process.hProcess,function,&memory,sizeof(memory))) {
                        for (const auto& module:modules) if (module.base==memory.AllocationBase) {
                            std::wprintf(L"IMPORT_SLOT rva=0x%llx module=%ls\n",rva,module.path.c_str());
                            found=true;
                            break;
                        }
                    }
                    if (!found) failed=true;
                }
                reached=true;
                std::puts("STOPPED_BEFORE_APPLICATION_ENTRY_NO_TLS_CALLBACKS");
                TerminateProcess(process.hProcess,0);
            } else if (record.ExceptionCode!=EXCEPTION_BREAKPOINT) {
                failed=true;
                TerminateProcess(process.hProcess,6);
            }
        } else if (event.dwDebugEventCode==EXIT_PROCESS_DEBUG_EVENT) exited=true;
        ContinueDebugEvent(event.dwProcessId,event.dwThreadId,DBG_CONTINUE);
        if (exited) break;
    }
    if (!exited) TerminateProcess(process.hProcess,7);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    CloseHandle(job);
    return reached && exited && !failed ? 0:1;
}
