#include <windows.h>
extern "C" __declspec(dllexport) INT_PTR CALLBACK FixtureClose(HWND dialog, UINT message, WPARAM, LPARAM) {
    if (message == WM_INITDIALOG) { EndDialog(dialog, 73); return TRUE; }
    return FALSE;
}
extern "C" __declspec(dllexport) INT_PTR WINAPI FixtureInvoke(HINSTANCE module, LPCWSTR name, DLGPROC callback, LPARAM parameter) {
    return DialogBoxParamW(module, name, nullptr, callback, parameter);
}
