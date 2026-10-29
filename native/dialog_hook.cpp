#include "dialog_hook.h"
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cwchar>

using DialogFunction = INT_PTR(WINAPI*)(HINSTANCE, LPCWSTR, HWND, DLGPROC, LPARAM);
struct ReminderRecord { DWORD bodyId; DWORD padding; LPCWSTR text; int delay; };
static_assert(offsetof(ReminderRecord, delay) == 16);
static HMODULE hostModule;
static wchar_t hostDirectory[MAX_PATH];
static size_t hostDirectoryLength;
static DialogFunction originalDialog;

static bool Readable(const void* pointer, size_t size) {
    MEMORY_BASIC_INFORMATION info{};
    if (!pointer || !VirtualQuery(pointer, &info, sizeof(info)) || info.State != MEM_COMMIT ||
        (info.Protect & (PAGE_GUARD | PAGE_NOACCESS))) return false;
    const auto offset = reinterpret_cast<uintptr_t>(pointer) - reinterpret_cast<uintptr_t>(info.BaseAddress);
    constexpr DWORD readable = PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                              PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
    return (info.Protect & readable) && offset < info.RegionSize && size <= info.RegionSize - offset;
}

static bool ReminderMatches(LPARAM parameter) {
    const auto record = reinterpret_cast<const ReminderRecord*>(parameter);
    if (!Readable(record, sizeof(ReminderRecord))) return false;
    __try {
        return record->bodyId == 0x291 && record->delay >= 0 && Readable(record->text, sizeof(wchar_t));
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

static bool HostCallback(DLGPROC callback) {
    MEMORY_BASIC_INFORMATION info{};
    const auto address = reinterpret_cast<const void*>(callback);
    return address && VirtualQuery(address, &info, sizeof(info)) && info.State == MEM_COMMIT &&
           info.Type == MEM_IMAGE && info.AllocationBase == hostModule &&
           !(info.Protect & (PAGE_GUARD | PAGE_NOACCESS)) &&
           (info.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY));
}

static bool ResourceModule(HMODULE module) {
    wchar_t path[MAX_PATH]{};
    if (!module) return false;
    const DWORD length = GetModuleFileNameW(module, path, ARRAYSIZE(path));
    if (!length || length >= ARRAYSIZE(path) || length <= hostDirectoryLength + 12 ||
        _wcsnicmp(path, hostDirectory, hostDirectoryLength)) return false;
    const wchar_t* name = path + hostDirectoryLength;
    return !_wcsnicmp(name, L"pl_rsrc_", 8) && !_wcsicmp(path + length - 4, L".dll") &&
           !wcschr(name, L'\\') && !wcschr(name, L'/');
}

static INT_PTR WINAPI FilterDialog(HINSTANCE module, LPCWSTR name, HWND parent, DLGPROC callback, LPARAM parameter) {
    const DWORD error = GetLastError();
    if (IS_INTRESOURCE(name)) {
        const auto id = reinterpret_cast<uintptr_t>(name);
        if ((id == 0xc3 || id == 0x13bf) && HostCallback(callback) && ResourceModule(module) &&
            FindResourceW(module, name, RT_DIALOG) && (id == 0x13bf || ReminderMatches(parameter))) {
            SetLastError(error);
            return 1;
        }
    }
    SetLastError(error);
    return originalDialog(module, name, parent, callback, parameter);
}

static void ReplaceImport(IMAGE_THUNK_DATA64* slot) {
    DWORD protection = 0;
    if (!slot->u1.Function || !VirtualProtect(slot, sizeof(*slot), PAGE_READWRITE, &protection)) return;
    originalDialog = reinterpret_cast<DialogFunction>(slot->u1.Function);
    InterlockedExchangePointer(reinterpret_cast<void* volatile*>(&slot->u1.Function), reinterpret_cast<void*>(FilterDialog));
    DWORD ignored = 0;
    if (!VirtualProtect(slot, sizeof(*slot), protection, &ignored)) {
        InterlockedCompareExchangePointer(reinterpret_cast<void* volatile*>(&slot->u1.Function),
                                         reinterpret_cast<void*>(originalDialog), reinterpret_cast<void*>(FilterDialog));
        VirtualProtect(slot, sizeof(*slot), protection, &ignored);
    }
}

static void Install() {
    hostModule = GetModuleHandleW(nullptr);
    const DWORD length = GetModuleFileNameW(hostModule, hostDirectory, ARRAYSIZE(hostDirectory));
    if (!length || length >= ARRAYSIZE(hostDirectory)) return;
    wchar_t* name = wcsrchr(hostDirectory, L'\\');
    if (!name || _wcsicmp(name + 1, L"ProcessLasso.exe")) return;
    name[1] = L'\0';
    hostDirectoryLength = name + 1 - hostDirectory;
    auto image = reinterpret_cast<BYTE*>(hostModule);
    const auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(image);
    if (!Readable(dos, sizeof(*dos)) || dos->e_magic != IMAGE_DOS_SIGNATURE ||
        dos->e_lfanew <= 0 || dos->e_lfanew > 0x100000) return;
    const auto nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(image + dos->e_lfanew);
    if (!Readable(nt, sizeof(*nt)) || nt->Signature != IMAGE_NT_SIGNATURE ||
        nt->FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64 ||
        nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) return;
    const DWORD size = nt->OptionalHeader.SizeOfImage;
    if (size < sizeof(IMAGE_NT_HEADERS64)) return;
    const auto imports = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!imports.VirtualAddress || imports.VirtualAddress >= size || imports.Size > size - imports.VirtualAddress) return;
    for (DWORD offset = 0; offset + sizeof(IMAGE_IMPORT_DESCRIPTOR) <= imports.Size; offset += sizeof(IMAGE_IMPORT_DESCRIPTOR)) {
        const auto entry = reinterpret_cast<const IMAGE_IMPORT_DESCRIPTOR*>(image + imports.VirtualAddress + offset);
        if (!entry->Name) break;
        if (entry->Name >= size || !memchr(image + entry->Name, 0, size - entry->Name) ||
            _stricmp(reinterpret_cast<const char*>(image + entry->Name), "USER32.dll")) continue;
        if (!entry->OriginalFirstThunk || !entry->FirstThunk) return;
        for (size_t index = 0; ; ++index) {
            const auto lookupRva = entry->OriginalFirstThunk + index * sizeof(IMAGE_THUNK_DATA64);
            const auto slotRva = entry->FirstThunk + index * sizeof(IMAGE_THUNK_DATA64);
            if (lookupRva > size - sizeof(IMAGE_THUNK_DATA64) || slotRva > size - sizeof(IMAGE_THUNK_DATA64)) return;
            const auto lookup = reinterpret_cast<const IMAGE_THUNK_DATA64*>(image + lookupRva);
            if (!lookup->u1.AddressOfData) break;
            if (IMAGE_SNAP_BY_ORDINAL64(lookup->u1.Ordinal) || lookup->u1.AddressOfData >= size - sizeof(IMAGE_IMPORT_BY_NAME)) continue;
            const auto symbol = reinterpret_cast<const IMAGE_IMPORT_BY_NAME*>(image + lookup->u1.AddressOfData);
            if (!memchr(symbol->Name, 0, size - lookup->u1.AddressOfData - 2) || strcmp(symbol->Name, "DialogBoxParamW")) continue;
            ReplaceImport(reinterpret_cast<IMAGE_THUNK_DATA64*>(image + slotRva));
            return;
        }
    }
}

void InstallDialogHook() {
    __try { Install(); } __except (EXCEPTION_EXECUTE_HANDLER) { }
}
