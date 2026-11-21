# A pad through GameInput (issue #15)

GDK games such as Forza Horizon 6 read their controllers through GameInput. This test checks Blackwell Engine's
GameInput (`dlls/gameinput`, patches 0012, 0015 and 0018) the ways a game may ask, against a stand-in XInput with
one DualSense that the test drives. No game and no controller are needed.

- `fake_xinput.c`, `fake_xinput.def`: a native `xinput1_4.dll` with one pad (054c:0ce6, as Wine's XInput reports a
  DualSense on a cable). `FakeXInputSet` sets its state.
- `pads_test.c`: finds the pad with a device callback for generic controllers and one for gamepads. It reads the pad
  as a gamepad, as a UI navigation device (menus) and as a generic controller (axes, buttons, switch), checks that it
  is not a racing wheel, that its rumble reaches XInput, and that it is reported gone once unplugged. Then, with no
  pad on XInput, it asks macOS for its own pads (GameController.framework).

## Run

```sh
x86_64-w64-mingw32-clang -O1 -shared -o xinput1_4.dll fake_xinput.c fake_xinput.def
cp <build>/include/gameinput.h inc/ && x86_64-w64-mingw32-clang -O1 -I inc -o pads_test.exe pads_test.c
WINEPREFIX=<prefix> WINE_GAMEINPUT=1 WINEDLLOVERRIDES="xinput1_4=n" arch -x86_64 <engine>/bin/wine pads_test.exe
```

`WINEDEBUG=+ginput` shows where each pad comes from ("connected through XInput" or "through macOS") and what
GameController.framework knows.

## Results (21 November 2026)

PASS, all 15 checks, on Blackwell Engine 1.3 and Blackwell Engine Steam 1.3 (Rosetta) and on Blackwell Engine
Native 1.3 (through FEX), each from its release tarball. GameController.framework loaded and answered in both kinds of
process, on a Mac with no controller (0 pads). A real pad on Bluetooth could not be tried there: nothing was paired.
