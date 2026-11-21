# Store ownership and gamer picture (issue #18)

What Forza Horizon 6 asks the Xbox runtime about the player: which of its add-ons the account owns (the in-game
store), its entitled products, its add-on licences (the VIP membership, the Car Pass) and the gamer picture. Before
MetalHorizon 1.1.1 every answer was "none" and the picture a grey square. This test asks the runtime the same
questions through its own interfaces, with no game, no account and no credentials.

- `ownership_test.c`: the Windows program. It calls `XStoreQueryAssociatedProductsAsync`,
  `XStoreQueryEntitledProductsAsync`, `XStoreQueryAddOnLicensesAsync` and `XUserGetGamerPictureAsync` (four sizes)
  through `QueryApiImpl`, and prints one line per fact.
- `fake_service.py`: a stand-in for xodus-service on its socket. It answers the Store frames with real answers that
  xodus-service made from the live catalog, and the picture frame with a PNG of the size asked. It logs every request.
- `check.py`: checks the program's output.
- `MicrosoftGame.config`: the game's Store ID, which the runtime reads next to the program.

## Run

```sh
# 1. real answers: the account owns the Deluxe Edition and some add-ons (public catalog data, no account)
XODUS_CATALOG_DUMP=<answers> cargo test --release --offline -p xodus-service -- --ignored the_runtime_test_answers
# 2. the program, against the runtime's generated headers
x86_64-w64-mingw32-clang -O1 -D__WINESRC__ -I <build>/dlls/xgameruntime -I <wine>/dlls/xgameruntime \
    -o ownership_test.exe ownership_test.c
cp MicrosoftGame.config <next to ownership_test.exe>
# 3. the stand-in service (a short folder: a socket path has at most 104 characters)
python3 -I fake_service.py <socket folder> <answers> service.log [normal|fail]
# 4. the program, then the check
WINEPREFIX=<prefix> XODUS_RUNTIME_DIR=<socket folder> XGR_STORE_CATALOG=1 arch -x86_64 <engine>/bin/wine ownership_test.exe > run.log 2>&1
python3 -I check.py normal run.log <answers>/owned.txt
```

Fallbacks: run the service with `fail`, or point `XODUS_RUNTIME_DIR` at an empty folder, or leave out
`XGR_STORE_CATALOG`. Then check with `python3 -I check.py fallback run.log`. The game must get what it got before
1.1.1: the game alone among the entitled products, no add-on licence, the plain picture, and never an error.

## Results (21 November 2026: Blackwell Engine 1.3 on Rosetta, Blackwell Engine Native 1.3 through FEX)

Normal run:
- The store listing has 34 durable add-ons; the 8 owned ones are marked owned, with their SKUs.
- Those 8 owned add-ons include the Car Pass and the Welcome Pack, which come from the Deluxe Edition only.
- The entitled products are the game and those 8 add-ons.
- There are 8 add-on licences ("<Store ID>/0010", active, no end).
- The gamer picture comes back as a PNG of 64, 208, 424 and 1080 pixels.
- Not marked: a Car Voucher the account owns, which is a consumable, not a durable add-on.

The same on both engines, from their release tarballs. Every fallback answers as before 1.1.1, with no error,
in about a second when there is no service.
