/* cpuidprobe: asks the (emulated) x86-64 CPU what it announces, via CPUID. Used to see whether Rosetta advertises
 * AVX / AVX2 to a Wine process (ROSETTA_ADVERTISE_AVX=1 or not). Reads only; changes nothing.
 * Build: x86_64-w64-mingw32-gcc -O1 -static -o cpuidprobe.exe cpuidprobe.c */
#include <stdio.h>
#include <string.h>
#include <intrin.h>

int main(void)
{
    int r[4], max;
    char vendor[13] = {0};
    __cpuid(r, 0); max = r[0];
    memcpy(vendor, &r[1], 4); memcpy(vendor + 4, &r[3], 4); memcpy(vendor + 8, &r[2], 4);
    printf("cpu vendor: %s   highest basic leaf: %d\n", vendor, max);
    __cpuid(r, 1);
    printf("SSE4.2: %s   OSXSAVE: %s   AVX: %s   FMA: %s\n", (r[2] >> 20) & 1 ? "yes" : "no", (r[2] >> 27) & 1 ? "yes" : "no",
           (r[2] >> 28) & 1 ? "yes" : "no", (r[2] >> 12) & 1 ? "yes" : "no");
    if (max >= 7) { __cpuidex(r, 7, 0); printf("AVX2: %s   BMI2: %s\n", (r[1] >> 5) & 1 ? "yes" : "no", (r[1] >> 8) & 1 ? "yes" : "no"); }
    printf("VERDICT: AVX is %s to this process\n", (((__cpuid(r, 1), r[2]) >> 28) & 1) ? "ADVERTISED" : "NOT advertised");
    return 0;
}
