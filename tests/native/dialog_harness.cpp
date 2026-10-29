#include <windows.h>
#include <commctrl.h>
#include <cstdio>
#include <string>
#include <vector>
struct ReminderRecord { DWORD bodyId; DWORD padding; LPCWSTR text; int delay; };
static int callbackCount;
static int failures;
static INT_PTR CALLBACK CloseDialog(HWND dialog, UINT message, WPARAM, LPARAM) {
    if (message == WM_INITDIALOG) { ++callbackCount; EndDialog(dialog, 73); return TRUE; }
    return FALSE;
}
static void Check(const char* name, INT_PTR actual, INT_PTR expected, int calls) {
    const bool pass = actual == expected && callbackCount == calls;
    std::printf("%s %s result=%lld callbacks=%d\n", pass ? "PASS" : "FAIL", name, actual, callbackCount);
    if (!pass) ++failures;
}
int wmain(int argc, wchar_t** argv) {
    if (argc != 3) return 2;
    const bool enabled = !wcscmp(argv[1], L"enabled");
    const std::wstring path = argv[2];
    INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_WIN95_CLASSES | ICC_STANDARD_CLASSES | ICC_LINK_CLASS};
    if (!InitCommonControlsEx(&controls) || !LoadLibraryExW(L"Msftedit.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32)) return 3;
    HMODULE resource = LoadLibraryW(path.c_str());
    HMODULE unrelated = LoadLibraryW(L"unrelated_resources.dll");
    const auto separator = path.find_last_of(L"\\/");
    const auto outsidePath = path.substr(0, separator + 1) + L"external\\" + path.substr(separator + 1);
    HMODULE outside = LoadLibraryW(outsidePath.c_str());
    HMODULE fixture = LoadLibraryW(L"dialog_fixture.dll");
    if (!resource || !unrelated || !outside || !fixture) return 3;
    DWORD handle = 0;
    const DWORD size = GetFileVersionInfoSizeW(path.c_str(), &handle);
    std::vector<BYTE> data(size);
    void* value = nullptr;
    UINT bytes = 0;
    if (!size || !GetFileVersionInfoW(path.c_str(), 0, size, data.data()) || !VerQueryValueW(data.data(), L"\\", &value, &bytes)) return 4;
    std::printf("PASS version-forwarding record_bytes=%u\n", bytes);
    ReminderRecord reminder{0x291, 0, L"", 3000};
    auto call = [&](const char* name, HMODULE module, UINT id, const ReminderRecord* record, bool suppress) {
        callbackCount = 0;
        SetLastError(1234);
        const auto result = DialogBoxParamW(module, MAKEINTRESOURCEW(id), nullptr, CloseDialog, reinterpret_cast<LPARAM>(record));
        const DWORD error = GetLastError();
        Check(name, result, enabled && suppress ? 1 : 73, enabled && suppress ? 0 : 1);
        if (enabled && suppress && error != 1234) ++failures;
    };
    call("reminder", resource, 0xc3, &reminder, true);
    reminder.delay = 0;
    call("reminder-zero-delay", resource, 0xc3, &reminder, true);
    call("offer", resource, 0x13bf, nullptr, true);
    reminder.bodyId = 0x1ce;
    call("feature-unavailable-preserved", resource, 0xc3, &reminder, false);
    call("other-dialog-preserved", resource, 0xc9, nullptr, false);
    reminder.bodyId = 0x291;
    call("unrelated-module-reminder", unrelated, 0xc3, &reminder, false);
    call("unrelated-module-offer", unrelated, 0x13bf, nullptr, false);
    call("other-directory-reminder", outside, 0xc3, &reminder, false);
    call("other-directory-offer", outside, 0x13bf, nullptr, false);
    call("null-record", resource, 0xc3, nullptr, false);
    call("unreadable-record", resource, 0xc3, reinterpret_cast<const ReminderRecord*>(1), false);
    reminder.delay = -1;
    call("unexpected-layout", resource, 0xc3, &reminder, false);
    reminder.delay = 0;
    reminder.text = nullptr;
    call("null-text", resource, 0xc3, &reminder, false);
    reminder.text = L"";
    void* unreadable = VirtualAlloc(nullptr, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_NOACCESS);
    call("noaccess-record", resource, 0xc3, reinterpret_cast<const ReminderRecord*>(unreadable), false);
    VirtualFree(unreadable, 0, MEM_RELEASE);
    auto externalClose = reinterpret_cast<DLGPROC>(GetProcAddress(fixture, "FixtureClose"));
    callbackCount = 0;
    Check("external-callback", DialogBoxParamW(resource, MAKEINTRESOURCEW(0xc3), nullptr, externalClose, reinterpret_cast<LPARAM>(&reminder)), 73, 0);
    using Invoke = INT_PTR(WINAPI*)(HINSTANCE, LPCWSTR, DLGPROC, LPARAM);
    auto externalInvoke = reinterpret_cast<Invoke>(GetProcAddress(fixture, "FixtureInvoke"));
    callbackCount = 0;
    Check("external-caller", externalInvoke(resource, MAKEINTRESOURCEW(0xc3), CloseDialog, reinterpret_cast<LPARAM>(&reminder)), 73, 1);
    callbackCount = 0;
    Check("missing-template", DialogBoxParamW(resource, MAKEINTRESOURCEW(0x6666), nullptr, CloseDialog, 0), -1, 0);
    std::printf("RESULT failures=%d\n", failures);
    return failures ? 1 : 0;
}
