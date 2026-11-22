/*
 * pads_test: a pad through Blackwell Engine's GameInput (dlls/gameinput), asked the ways a GDK game may ask, against
 * fake_xinput.dll's DualSense (engine/tests/gameinput-pads). One "ok" or "FAIL" line per check.
 *
 * - found by a device callback for generic controllers (GameInputKindController), as a racing game that also takes
 *   wheels may look for it, and by one for gamepads, with the kinds and the counts Windows gives an Xbox pad;
 * - read as a gamepad, as a UI navigation device (the menus) and as a generic controller (axes, buttons, switch);
 * - not a racing wheel; its rumble reaches XInput; unplugged, it is reported gone and has no reading.
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#define COBJMACROS
#include <windows.h>
#include <stdio.h>
#include <stdbool.h>
#include <xinput.h>
#include <initguid.h>
#include "gameinput.h"

typedef HRESULT (WINAPI *create_fn)( v0_IGameInput ** );
typedef void (WINAPI *set_fn)( BOOL, WORD, BYTE, BYTE, SHORT, SHORT, SHORT, SHORT );
typedef void (WINAPI *motors_fn)( WORD *, WORD * );

static int failures;
static volatile LONG connects, disconnects, dispatched;
static v2_IGameInputDevice *seen;

static void check( BOOL ok, const char *what )
{
    printf( "%s %s\n", ok ? "ok  " : "FAIL", what );
    if (!ok) failures++;
}

static void __stdcall on_device( GameInputCallbackToken token, void *context, v2_IGameInputDevice *device,
                                 uint64_t timestamp, GameInputDeviceStatus current, GameInputDeviceStatus previous )
{
    if ((current & GameInputDeviceConnected) && !(previous & GameInputDeviceConnected)) { seen = device; InterlockedIncrement( &connects ); }
    if (!(current & GameInputDeviceConnected) && (previous & GameInputDeviceConnected)) InterlockedIncrement( &disconnects );
}

static void __stdcall on_dispatched( GameInputCallbackToken token, void *context, v2_IGameInputDevice *device,
                                     uint64_t timestamp, GameInputDeviceStatus current, GameInputDeviceStatus previous )
{
    InterlockedIncrement( &dispatched );
}

static v2_IGameInputReading *reading_of( v2_IGameInput *gi, GameInputKind kind )
{
    v2_IGameInputReading *reading = NULL;
    return SUCCEEDED(v2_IGameInput_GetCurrentReading( gi, kind, NULL, &reading )) ? reading : NULL;
}

int main( void )
{
    HMODULE gameinput = LoadLibraryA( "gameinput.dll" ), xinput = LoadLibraryA( "xinput1_4.dll" );
    create_fn create = gameinput ? (create_fn)(void *)GetProcAddress( gameinput, "GameInputCreate" ) : NULL;
    set_fn set = xinput ? (set_fn)(void *)GetProcAddress( xinput, "FakeXInputSet" ) : NULL;
    motors_fn motors = xinput ? (motors_fn)(void *)GetProcAddress( xinput, "FakeXInputMotors" ) : NULL;
    const v2_GameInputDeviceInfo *info = NULL;
    GameInputCallbackToken token = 0, gamepads = 0;
    v2_IGameInputReading *reading;
    GameInputGamepadState pad;
    GameInputUiNavigationState nav;
    GameInputSwitchPosition position;
    GameInputRumbleParams rumble = { 0.5f, 1.0f, 0.0f, 0.0f };
    v0_IGameInput *v0 = NULL;
    v2_IGameInput *gi = NULL;
    float axes[8];
    bool buttons[12];
    WORD low = 0, high = 0;
    int i;

    if (!create || !set || !motors) { printf( "FAIL no gameinput.dll, or not the fake xinput1_4.dll\n" ); return 2; }
    check( SUCCEEDED(create( &v0 )) && SUCCEEDED(v0_IGameInput_QueryInterface( v0, &IID_v2_IGameInput, (void **)&gi )),
           "GameInputCreate, and its v2 interface" );
    if (!gi) return 1;

    /* a DualSense on a cable, as Wine's XInput reports one: A held, left stick up, D-pad right, left trigger in */
    set( TRUE, XINPUT_GAMEPAD_A | XINPUT_GAMEPAD_DPAD_RIGHT, 255, 0, 0, 32767, 0, 0 );
    check( SUCCEEDED(v2_IGameInput_RegisterDeviceCallback( gi, NULL, GameInputKindController, GameInputDeviceConnected,
                                                           GameInputBlockingEnumeration, NULL, on_device, &token )) &&
           connects == 1, "found by a device callback for generic controllers" );
    check( SUCCEEDED(v2_IGameInput_RegisterDeviceCallback( gi, NULL, GameInputKindGamepad, GameInputDeviceConnected,
                                                           GameInputBlockingEnumeration, NULL, on_device, &gamepads )) &&
           connects == 2, "found by a device callback for gamepads" );
    if (seen && SUCCEEDED(v2_IGameInputDevice_GetDeviceInfo( seen, &info )) && info)
    {
        printf( "     %s %04x:%04x, input %#x, axes %u, buttons %u, switches %u\n", info->displayName, info->vendorId,
                info->productId, info->supportedInput, info->controllerAxisCount, info->controllerButtonCount,
                info->controllerSwitchCount );
        check( (info->supportedInput & (GameInputKindGamepad | GameInputKindController | GameInputKindUiNavigation)) ==
               (GameInputKindGamepad | GameInputKindController | GameInputKindUiNavigation),
               "a gamepad, a generic controller and a UI navigation device, as an Xbox pad is on Windows" );
        check( info->vendorId == 0x045e && info->productId == 0x02ea && !strcmp( info->displayName, "PlayStation Controller" ),
               "reported as an Xbox One controller, with its own name" );
        check( info->controllerAxisCount == 6 && info->controllerButtonCount == 10 && info->controllerSwitchCount == 1 &&
               info->controllerAxisInfo && info->controllerButtonInfo && info->controllerSwitchInfo && info->uiNavigationInfo &&
               info->controllerButtonInfo[0].label == GameInputLabelXboxA,
               "six axes, ten buttons and a switch, each described" );
    }
    else check( FALSE, "the pad's device information" );

    reading = reading_of( gi, GameInputKindGamepad );
    check( reading && v2_IGameInputReading_GetGamepadState( reading, &pad ) && (pad.buttons & GameInputGamepadA) &&
           (pad.buttons & GameInputGamepadDPadRight) && pad.leftThumbstickY > 0.99f && pad.leftTrigger > 0.99f,
           "read as a gamepad" );
    if (reading) v2_IGameInputReading_Release( reading );

    reading = reading_of( gi, GameInputKindUiNavigation );
    check( reading && v2_IGameInputReading_GetUiNavigationState( reading, &nav ) &&
           nav.buttons == (GameInputUiNavigationAccept | GameInputUiNavigationRight | GameInputUiNavigationUp | GameInputUiNavigationPageUp),
           "read as a UI navigation device: A accepts, the D-pad and the stick move, the trigger pages" );
    if (reading) v2_IGameInputReading_Release( reading );

    reading = reading_of( gi, GameInputKindController );
    if (reading)
    {
        UINT32 n = v2_IGameInputReading_GetControllerAxisState( reading, 8, axes );
        UINT32 b = v2_IGameInputReading_GetControllerButtonState( reading, 12, buttons );
        UINT32 s = v2_IGameInputReading_GetControllerSwitchState( reading, 1, &position );
        printf( "     axes %u: %.2f %.2f %.2f %.2f %.2f %.2f, buttons %u, A %d B %d, switch %u at %d\n", n, axes[0], axes[1],
                axes[2], axes[3], axes[4], axes[5], b, buttons[0], buttons[1], s, position );
        check( n == 6 && axes[0] == 0.5f && axes[1] < 0.01f && axes[4] > 0.99f && axes[5] == 0.0f && b == 10 && buttons[0] &&
               !buttons[1] && s == 1 && position == GameInputSwitchRight, "read as a generic controller" );
        v2_IGameInputReading_Release( reading );
    }
    else check( FALSE, "read as a generic controller" );
    check( !reading_of( gi, GameInputKindRacingWheel ), "not a racing wheel" );

    if (seen)
    {
        v2_IGameInputDevice_SetRumbleState( seen, &rumble );
        motors( &low, &high );
        check( low == 32767 && high == 65535, "its rumble reaches XInput" );
    }

    /* a game that runs the callbacks itself: nothing until it calls Dispatch, then the device */
    {
        IGameInputDispatcher *dispatcher = NULL;
        GameInputCallbackToken later = 0;
        HANDLE wait = NULL;
        BOOL waited;
        bool more;
        check( SUCCEEDED(v2_IGameInput_CreateDispatcher( gi, &dispatcher )) && dispatcher, "a dispatcher is made" );
        if (dispatcher)
        {
            v2_IGameInput_RegisterDeviceCallback( gi, NULL, GameInputKindGamepad, GameInputDeviceConnected,
                                                  GameInputAsyncEnumeration, NULL, on_dispatched, &later );
            Sleep( 300 );
            check( dispatched == 0, "with a dispatcher, no callback runs before Dispatch" );
            check( SUCCEEDED(IGameInputDispatcher_OpenWaitHandle( dispatcher, &wait )) && wait, "its wait handle" );
            waited = wait && WaitForSingleObject( wait, 2000 ) == WAIT_OBJECT_0;
            check( waited, "the wait handle is set while a callback waits" );
            more = IGameInputDispatcher_Dispatch( dispatcher, 0 );
            check( dispatched == 1 && !more, "Dispatch runs the waiting callback, and nothing is left" );
            if (wait) CloseHandle( wait );
            v2_IGameInput_UnregisterCallback( gi, later );
            IGameInputDispatcher_Release( dispatcher );
        }
    }

    set( FALSE, 0, 0, 0, 0, 0, 0, 0 );
    for (i = 0; i < 40 && !disconnects; i++) Sleep( 25 );
    check( disconnects >= 1, "unplugged: reported gone" );
    check( !reading_of( gi, GameInputKindGamepad ), "unplugged: no gamepad reading" );
    /* with no pad on XInput the pads macOS knows are asked for: no crash, whatever this Mac has paired */
    for (i = 0; i < 10; i++) { reading = reading_of( gi, GameInputKindGamepad ); if (reading) v2_IGameInputReading_Release( reading ); Sleep( 20 ); }
    printf( "     pads from macOS seen after unplugging: %ld\n", connects - 2 );
    check( TRUE, "asking macOS for its pads" );

    check( v2_IGameInput_UnregisterCallback( gi, token ) && v2_IGameInput_UnregisterCallback( gi, gamepads ), "callbacks unregistered" );
    v2_IGameInput_Release( gi );
    v0_IGameInput_Release( v0 );
    printf( "%s\n", failures ? "FAILED" : "PASS" );
    return failures ? 1 : 0;
}
