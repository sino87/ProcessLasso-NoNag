#include <windows.h>
static void NTAPI BeforeEntry(PVOID, DWORD reason, PVOID) {
    if (reason == DLL_PROCESS_ATTACH) ExitProcess(99);
}
#pragma const_seg(".CRT$XLB")
extern "C" const PIMAGE_TLS_CALLBACK NoNagTlsCallback = BeforeEntry;
#pragma const_seg()
#pragma comment(linker, "/INCLUDE:_tls_used")
#pragma comment(linker, "/INCLUDE:NoNagTlsCallback")
int main() { return 98; }
