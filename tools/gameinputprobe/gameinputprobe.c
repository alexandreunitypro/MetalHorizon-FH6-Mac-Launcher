/*
 * gameinputprobe: checks engine patch 0012 (GameInput on top of XInput) from inside Wine, the way a GDK game
 * uses it: GameInputCreate, QueryInterface for the v2 interface the GDK's C++ header asks for, a blocking device
 * enumeration, then current readings for gamepads, keyboard and mouse. Prints one line per step; exit code 0 when
 * the plumbing works. A controller is optional: without one the gamepad reading is "not found", as on Windows.
 *   x86_64-w64-mingw32-gcc -O2 -o gameinputprobe.exe gameinputprobe.c
 *   WINE_GAMEINPUT=1 wine gameinputprobe.exe [seconds to poll the first pad, default 0]
 * Self-contained on purpose (no GDK headers): vtable slots are numbered after Wine's include/gameinput.idl.
 */
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

typedef HRESULT (WINAPI *GameInputCreate_t)(void **);
static const GUID IID_v2 = {0xbbaa66d2,0x837a,0x40f7,{0xa3,0x03,0x91,0x7d,0x50,0x09,0x55,0xf4}};

#define KIND_KEYBOARD 0x10
#define KIND_MOUSE    0x20
#define KIND_GAMEPAD  0x40000

typedef void **VT;
#define SLOT(obj, n) ((*(VT *)(obj))[n])

typedef struct { float l; float r; } unused_t;
typedef struct { uint32_t buttons; float lt, rt, lx, ly, rx, ry; } gamepad_state;

/* v2_GameInputDeviceInfo: vendorId, productId, revisionNumber, usage{page,id}, hardware/firmware versions (2x8),
 * deviceId[32], deviceRootId[32], deviceFamily, supportedInput, rumble, system buttons, containerId (16),
 * displayName ... read through offsetof-free copying of the fields we print */
typedef struct
{
    uint16_t vendorId, productId, revisionNumber;
    uint16_t usagePage, usageId;
    uint16_t hw[4], fw[4];
    BYTE deviceId[32], deviceRootId[32];
    int32_t family;
    uint32_t supportedInput, rumble, systemButtons;
    GUID container;
    const char *displayName;
} device_info_v2;

static int devices_seen;

static void WINAPI device_callback(uint64_t token, void *ctx, void *device, uint64_t ts, uint32_t current, uint32_t previous)
{
    const device_info_v2 *info = NULL;
    HRESULT hr = ((HRESULT (WINAPI *)(void *, const device_info_v2 **))SLOT(device, 3))(device, &info);
    devices_seen++;
    printf("  device: %s, %04x:%04x, input %#x, status %#x -> %#x (%#lx)\n",
           info && info->displayName ? info->displayName : "?", info ? info->vendorId : 0, info ? info->productId : 0,
           info ? info->supportedInput : 0, previous, current, hr);
}

static int reading(void *gi, uint32_t kind, const char *what)
{
    void *r = NULL;
    HRESULT hr = ((HRESULT (WINAPI *)(void *, uint32_t, void *, void **))SLOT(gi, 4))(gi, kind, NULL, &r);
    if (FAILED(hr)) { printf("  %s reading: %#lx%s\n", what, hr, hr == (HRESULT)0x838a0003 ? " (none)" : ""); return hr == (HRESULT)0x838a0003; }
    uint32_t got = ((uint32_t (WINAPI *)(void *))SLOT(r, 3))(r);
    uint64_t ts = ((uint64_t (WINAPI *)(void *))SLOT(r, 4))(r);
    uint32_t keys = ((uint32_t (WINAPI *)(void *))SLOT(r, 12))(r);
    gamepad_state pad = {0};
    bool isPad = ((bool (WINAPI *)(void *, gamepad_state *))SLOT(r, 18))(r, &pad);
    printf("  %s reading: kind %#x, timestamp %llu, keys down %u, gamepad %d (buttons %#x lx %.2f ly %.2f lt %.2f)\n",
           what, got, (unsigned long long)ts, keys, isPad, pad.buttons, pad.lx, pad.ly, pad.lt);
    ((ULONG (WINAPI *)(void *))SLOT(r, 2))(r);
    return 1;
}

int main(int argc, char **argv)
{
    int seconds = argc > 1 ? atoi(argv[1]) : 0, ok = 1;
    HMODULE mod = LoadLibraryA("gameinput.dll");
    GameInputCreate_t create = mod ? (GameInputCreate_t)GetProcAddress(mod, "GameInputCreate") : NULL;
    void *v0 = NULL, *gi = NULL;
    uint64_t token = 0;
    HRESULT hr;

    if (!create) { printf("FAIL: no gameinput.dll / GameInputCreate\n"); return 2; }
    hr = create(&v0);
    printf("GameInputCreate: %#lx\n", hr);
    if (FAILED(hr)) { printf("FAIL: GameInputCreate (WINE_GAMEINPUT=1 set?)\n"); return 1; }
    hr = ((HRESULT (WINAPI *)(void *, const GUID *, void **))SLOT(v0, 0))(v0, &IID_v2, &gi);
    printf("QueryInterface(v2_IGameInput): %#lx\n", hr);
    if (FAILED(hr)) return 1;
    uint64_t now = ((uint64_t (WINAPI *)(void *))SLOT(gi, 3))(gi);
    printf("GetCurrentTimestamp: %llu us\n", (unsigned long long)now);
    /* v2 RegisterDeviceCallback is slot 8: device, kind, filter, enumeration (2 = blocking), context, callback, token */
    hr = ((HRESULT (WINAPI *)(void *, void *, uint32_t, uint32_t, uint32_t, void *, void *, uint64_t *))SLOT(gi, 8))
         (gi, NULL, KIND_GAMEPAD | KIND_KEYBOARD | KIND_MOUSE, 0xffffffff, 2, NULL, device_callback, &token);
    printf("RegisterDeviceCallback (blocking): %#lx, token %llu, %d devices\n", hr, (unsigned long long)token, devices_seen);
    if (FAILED(hr) || devices_seen < 2) ok = 0;
    ok &= reading(gi, KIND_KEYBOARD, "keyboard");
    ok &= reading(gi, KIND_MOUSE, "mouse");
    ok &= reading(gi, KIND_GAMEPAD, "gamepad");
    for (int i = 0; i < seconds * 10; i++) { Sleep(100); if (i % 10 == 0) reading(gi, KIND_GAMEPAD, "gamepad"); }
    /* v2 UnregisterCallback is slot 12 (13 is CreateDispatcher) */
    bool unregistered = ((bool (WINAPI *)(void *, uint64_t))SLOT(gi, 12))(gi, token);
    printf("UnregisterCallback: %d\n", unregistered);
    ((ULONG (WINAPI *)(void *))SLOT(gi, 2))(gi);
    ((ULONG (WINAPI *)(void *))SLOT(v0, 2))(v0);
    printf("%s\n", ok && unregistered ? "PASS" : "FAIL");
    return ok && unregistered ? 0 : 1;
}
