#include <windows.h>
#include <cstdio>
#include <vector>
int wmain(int argc, wchar_t** argv) {
    if (argc != 2) return 2;
    HMODULE proxy = LoadLibraryW(L"version.dll");
    wchar_t system[MAX_PATH]{};
    GetSystemDirectoryW(system, ARRAYSIZE(system));
    wcscat_s(system, L"\\version.dll");
    HMODULE real = LoadLibraryExW(system, nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!proxy || !real || proxy == real) return 3;
    const char* names[] = {"GetFileVersionInfoA","GetFileVersionInfoByHandle","GetFileVersionInfoExA","GetFileVersionInfoExW","GetFileVersionInfoSizeA","GetFileVersionInfoSizeExA","GetFileVersionInfoSizeExW","GetFileVersionInfoSizeW","GetFileVersionInfoW","VerFindFileA","VerFindFileW","VerInstallFileA","VerInstallFileW","VerLanguageNameA","VerLanguageNameW","VerQueryValueA","VerQueryValueW"};
    for (WORD i=0; i<17; ++i) {
        if (GetProcAddress(proxy,names[i]) != GetProcAddress(proxy,MAKEINTRESOURCEA(i+1)) ||
            !GetProcAddress(real,names[i]) || GetProcAddress(real,names[i]) != GetProcAddress(real,MAKEINTRESOURCEA(i+1))) return 4;
    }
    char file[MAX_PATH]{};
    if (!WideCharToMultiByte(CP_ACP,0,argv[1],-1,file,ARRAYSIZE(file),nullptr,nullptr)) return 5;
    DWORD handle1=0, handle2=0;
    auto sizeW = reinterpret_cast<decltype(&GetFileVersionInfoSizeW)>(GetProcAddress(real,"GetFileVersionInfoSizeW"));
    DWORD a = GetFileVersionInfoSizeW(argv[1],&handle1), b = sizeW(argv[1],&handle2);
    if (!a || a!=b || handle1!=handle2) return 6;
    std::vector<BYTE> one(a),two(b);
    auto infoW = reinterpret_cast<decltype(&GetFileVersionInfoW)>(GetProcAddress(real,"GetFileVersionInfoW"));
    if (!GetFileVersionInfoW(argv[1],0,a,one.data()) || !infoW(argv[1],0,b,two.data()) || one!=two) return 7;
    void *v1=nullptr,*v2=nullptr;
    UINT n1=0,n2=0;
    auto queryW = reinterpret_cast<decltype(&VerQueryValueW)>(GetProcAddress(real,"VerQueryValueW"));
    if (!VerQueryValueW(one.data(),L"\\",&v1,&n1) || !queryW(two.data(),L"\\",&v2,&n2) || n1!=n2 || memcmp(v1,v2,n1)) return 8;
    if (!GetFileVersionInfoSizeA(file,&handle1) || !GetFileVersionInfoA(file,0,a,one.data()) || !VerQueryValueA(one.data(),"\\",&v1,&n1)) return 9;
    if (!GetFileVersionInfoSizeExW(FILE_VER_GET_NEUTRAL,argv[1],&handle1) || !GetFileVersionInfoExW(FILE_VER_GET_NEUTRAL,argv[1],0,a,one.data()) ||
        !GetFileVersionInfoSizeExA(FILE_VER_GET_NEUTRAL,file,&handle1) || !GetFileVersionInfoExA(FILE_VER_GET_NEUTRAL,file,0,a,one.data())) return 10;
    wchar_t w1[128]{}, w2[128]{};
    char c1[128]{}, c2[128]{};
    auto languageW = reinterpret_cast<decltype(&VerLanguageNameW)>(GetProcAddress(real,"VerLanguageNameW"));
    auto languageA = reinterpret_cast<decltype(&VerLanguageNameA)>(GetProcAddress(real,"VerLanguageNameA"));
    if (VerLanguageNameW(0x409,w1,128)!=languageW(0x409,w2,128) || wcscmp(w1,w2) ||
        VerLanguageNameA(0x409,c1,128)!=languageA(0x409,c2,128) || strcmp(c1,c2)) return 11;
    SetLastError(4567);
    GetFileVersionInfoSizeW(L"nonexistent-nonag-test-file", &handle1);
    const DWORD proxyError=GetLastError();
    SetLastError(4567);
    sizeW(L"nonexistent-nonag-test-file", &handle2);
    if (GetLastError()!=proxyError) return 12;
    UINT ca=128, cb=128, da=128, db=128;
    auto findW = reinterpret_cast<decltype(&VerFindFileW)>(GetProcAddress(real,"VerFindFileW"));
    wchar_t dest1[128]{},dest2[128]{};
    const DWORD fw1=VerFindFileW(0,L"missing-nonag-file",L".",L".",w1,&ca,dest1,&da);
    const DWORD fw2=findW(0,L"missing-nonag-file",L".",L".",w2,&cb,dest2,&db);
    if (fw1!=fw2 || ca!=cb || da!=db || wcscmp(w1,w2) || wcscmp(dest1,dest2)) return 13;
    ca=cb=da=db=128;
    auto findA = reinterpret_cast<decltype(&VerFindFileA)>(GetProcAddress(real,"VerFindFileA"));
    char destA1[128]{},destA2[128]{};
    const DWORD fa1=VerFindFileA(0,"missing-nonag-file",".",".",c1,&ca,destA1,&da);
    const DWORD fa2=findA(0,"missing-nonag-file",".",".",c2,&cb,destA2,&db);
    if (fa1!=fa2 || ca!=cb || da!=db || strcmp(c1,c2) || strcmp(destA1,destA2)) return 14;
    ca=cb=128;
    w1[0]=w2[0]=L'\0'; c1[0]=c2[0]='\0';
    auto installW = reinterpret_cast<decltype(&VerInstallFileW)>(GetProcAddress(real,"VerInstallFileW"));
    const DWORD iw1=VerInstallFileW(0,L"missing-source-nonag",L"missing-dest-nonag",L".",L".",L".",w1,&ca);
    const DWORD iw2=installW(0,L"missing-source-nonag",L"missing-dest-nonag",L".",L".",L".",w2,&cb);
    if (iw1!=iw2 || ca!=cb || wcscmp(w1,w2)) return 15;
    ca=cb=128;
    auto installA = reinterpret_cast<decltype(&VerInstallFileA)>(GetProcAddress(real,"VerInstallFileA"));
    const DWORD ia1=VerInstallFileA(0,"missing-source-nonag","missing-dest-nonag",".",".",".",c1,&ca);
    const DWORD ia2=installA(0,"missing-source-nonag","missing-dest-nonag",".",".",".",c2,&cb);
    if (ia1!=ia2 || ca!=cb || strcmp(c1,c2)) return 16;
    std::puts("PASS VERSION names, ordinals, A/W/Ex queries, output data and errors");
    FreeLibrary(proxy);
    FreeLibrary(real);
    return 0;
}
