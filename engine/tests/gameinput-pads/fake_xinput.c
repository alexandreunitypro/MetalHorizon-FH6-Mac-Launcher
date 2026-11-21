/*
 * fake_xinput: a stand-in xinput1_4.dll with one pad the test drives (engine/tests/gameinput-pads). It reports a
 * DualSense (054c:0ce6), as Wine's XInput does for one on a cable, and FakeXInputSet sets its state.
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#include <windows.h>
#include <xinput.h>

static XINPUT_STATE pad;
static BOOL connected;
static XINPUT_VIBRATION motors;

DWORD WINAPI XInputGetState( DWORD index, XINPUT_STATE *state )
{
    if (index || !connected) return ERROR_DEVICE_NOT_CONNECTED;
    *state = pad;
    state->Gamepad.wButtons &= ~0x0400; /* the guide is XInputGetStateEx's only */
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputGetStateEx( DWORD index, XINPUT_STATE *state )
{
    if (index || !connected) return ERROR_DEVICE_NOT_CONNECTED;
    *state = pad;
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputSetState( DWORD index, XINPUT_VIBRATION *vibration )
{
    if (index || !connected) return ERROR_DEVICE_NOT_CONNECTED;
    motors = *vibration;
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputGetCapabilities( DWORD index, DWORD flags, XINPUT_CAPABILITIES *caps )
{
    if (index || !connected) return ERROR_DEVICE_NOT_CONNECTED;
    memset( caps, 0, sizeof(*caps) );
    caps->Type = XINPUT_DEVTYPE_GAMEPAD;
    caps->SubType = XINPUT_DEVSUBTYPE_GAMEPAD;
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputGetCapabilitiesEx( DWORD unknown, DWORD index, DWORD flags, XINPUT_CAPABILITIES_EX *caps )
{
    if (index || !connected) return ERROR_DEVICE_NOT_CONNECTED;
    memset( caps, 0, sizeof(*caps) );
    caps->Capabilities.Type = XINPUT_DEVTYPE_GAMEPAD;
    caps->Capabilities.SubType = XINPUT_DEVSUBTYPE_GAMEPAD;
    caps->VendorId = 0x054c;
    caps->ProductId = 0x0ce6;
    caps->VersionNumber = 0x0100;
    return ERROR_SUCCESS;
}

void WINAPI XInputEnable( BOOL enable )
{
}

/* the test's hook: the pad's state, a new packet each time */
void WINAPI FakeXInputSet( BOOL present, WORD buttons, BYTE left_trigger, BYTE right_trigger,
                           SHORT left_x, SHORT left_y, SHORT right_x, SHORT right_y )
{
    connected = present;
    pad.dwPacketNumber++;
    pad.Gamepad.wButtons = buttons;
    pad.Gamepad.bLeftTrigger = left_trigger;
    pad.Gamepad.bRightTrigger = right_trigger;
    pad.Gamepad.sThumbLX = left_x;
    pad.Gamepad.sThumbLY = left_y;
    pad.Gamepad.sThumbRX = right_x;
    pad.Gamepad.sThumbRY = right_y;
}

void WINAPI FakeXInputMotors( WORD *left, WORD *right )
{
    *left = motors.wLeftMotorSpeed;
    *right = motors.wRightMotorSpeed;
}
