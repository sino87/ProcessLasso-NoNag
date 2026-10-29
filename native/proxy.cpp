#include <windows.h>
#include "dialog_hook.h"

extern "C" { FARPROC VersionFunctions[17]{}; }
static INIT_ONCE initialization = INIT_ONCE_STATIC_INIT;
static const char* const names[] = {
    "GetFileVersionInfoA", "GetFileVersionInfoByHandle", "GetFileVersionInfoExA", "GetFileVersionInfoExW",
    "GetFileVersionInfoSizeA", "GetFileVersionInfoSizeExA", "GetFileVersionInfoSizeExW", "GetFileVersionInfoSizeW",
    "GetFileVersionInfoW", "VerFindFileA", "VerFindFileW", "VerInstallFileA", "VerInstallFileW",
    "VerLanguageNameA", "VerLanguageNameW", "VerQueryValueA", "VerQueryValueW"
};

static BOOL CALLBACK Initialize(PINIT_ONCE, PVOID, PVOID*) {
    wchar_t path[MAX_PATH]{};
    const UINT length = GetSystemDirectoryW(path, ARRAYSIZE(path));
    if (!length || length >= ARRAYSIZE(path) - 13) return FALSE;
    wcscat_s(path, L"\\version.dll");
    HMODULE module = LoadLibraryExW(path, nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) return FALSE;
    for (size_t i = 0; i < ARRAYSIZE(names); ++i) {
        VersionFunctions[i] = GetProcAddress(module, names[i]);
        if (!VersionFunctions[i]) return FALSE;
    }
    return TRUE;
}

extern "C" void ResolveVersionExport() {
    const DWORD error = GetLastError();
    if (!InitOnceExecuteOnce(&initialization, Initialize, nullptr, nullptr)) {
        RaiseFailFastException(nullptr, nullptr, 0);
    }
    SetLastError(error);
}

BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) InstallDialogHook();
    return TRUE;
}
