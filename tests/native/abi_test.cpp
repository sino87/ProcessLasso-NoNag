#include <windows.h>
#include <cstdio>
extern "C" { FARPROC VersionFunctions[17]{}; }
extern "C" void ResolveVersionExport() { SetLastError(1234); }
using IntegerCall = unsigned long long(*)(unsigned long long, unsigned long long, unsigned long long, unsigned long long, unsigned long long, unsigned long long);
using FloatCall = double(*)(double, double, double, double, double, double);
static unsigned long long Integers(unsigned long long a, unsigned long long b, unsigned long long c, unsigned long long d, unsigned long long e, unsigned long long f) { return a + b*2 + c*3 + d*4 + e*5 + f*6; }
static double Floats(double a, double b, double c, double d, double e, double f) { return a + b*2 + c*3 + d*4 + e*5 + f*6; }
#define DECLARE(n) extern "C" void Forward##n();
DECLARE(0) DECLARE(1) DECLARE(2) DECLARE(3) DECLARE(4) DECLARE(5) DECLARE(6) DECLARE(7) DECLARE(8)
DECLARE(9) DECLARE(10) DECLARE(11) DECLARE(12) DECLARE(13) DECLARE(14) DECLARE(15) DECLARE(16)
int main() {
    void(*const forwards[])() = {Forward0,Forward1,Forward2,Forward3,Forward4,Forward5,Forward6,Forward7,Forward8,Forward9,Forward10,Forward11,Forward12,Forward13,Forward14,Forward15,Forward16};
    for (size_t i=0; i<17; ++i) {
        VersionFunctions[i] = reinterpret_cast<FARPROC>(Integers);
        if (reinterpret_cast<IntegerCall>(forwards[i])(1,2,3,4,5,0x100000006ULL) != Integers(1,2,3,4,5,0x100000006ULL)) return 1;
        VersionFunctions[i] = reinterpret_cast<FARPROC>(Floats);
        if (reinterpret_cast<FloatCall>(forwards[i])(1.5,2.5,3.5,4.5,5.5,6.5) != Floats(1.5,2.5,3.5,4.5,5.5,6.5)) return 1;
    }
    std::puts("PASS 17 thunks: integer, floating-point, stack arguments and return values");
}
