# Native gameplay additions v1

Built on Subnautica ESP baseline `b5d6c2c`. The existing ESP enumeration and
viewport drawing code are unchanged. GOI and the shared menu renderer are untouched.

## Subnautica / Mods

- Held-tool recharge via `Inventory.main.GetHeldObject`, `GameObject.GetComponent`
  and `EnergyMixin.AddEnergy`. No world-wide battery scan, no vehicle/base energy edits.
- Auto-heal and heal-now via the live player's `LiveMixin.AddHealth`. Checks alive,
  normal mode, cinematic and teleport state. Not invincibility against one-shot damage.
- Position/depth HUD at 2 Hz, independent of the 60 Hz ESP display link.
- Three session-only swim bookmarks and return jump via `Player.SetPosition(Vector3)`.
  Requires free outdoor swimming, normal mode, no cinematic/teleport, maximum 100m.
  Each move requires confirmation: destination collision clearance is NOT tested.
- New automation defaults off and clears when player instance changes/disappears.
  Refilled health/charge and position can naturally be serialized by the game.

## Clover Pit / Lab

- Add 1,000 / 10,000 / 100,000 coins. Resolve the exact Int32 conversion overload
  of `System.Numerics.BigInteger`; pin the boxed argument during `CoinsAdd`.
  Does not count granted coins as earned-coin statistics.
- Interest rate 0–100%; initial UI value is read from the current game.
- Clover, diamond and seven spawn-weight boosts (5x or 20x), relative to a captured
  baseline, not cumulative. Does not promise guaranteed rolls or unlock symbols.
- Restore captured interest and all nine current symbol weights in the same run.
  Uses `Symbol_Chance_Get(kind,false,false)`, NOT `GetBasic` (constant defaults).
  This distinction was checked against the pulled binary's disassembly.
- All new edits require live slot singleton and idle state 3. Run object and seed
  identify snapshots; snapshots do not survive app restarts. Coin grants are not undone.

## Verification / deployment

`tools/verify_native_mods.py` checks exact local metadata signatures and preservation
of the known-working ESP functions. This is not a functional game test.

New feature calls use IL2CPP metadata/runtime invocation; no new RVAs, inline hooks,
raw game field offsets, loader changes or executable page writes.

Build on macOS with the existing iOS CI. Keep a pull-back backup of each installed
dylib before replacement. Subnautica's current assignment is `SN ESP`, filename
`EmberSubnautica.dylib`; update that existing file, not a new folder. Clover is
`Clover Pit/CloverPit.dylib`, which the host redeploys: update the bundled host too
or it will overwrite a manual Clover push. Do not relabel an unsigned/local build
as installed or runtime-verified. Keep guest save/data assignments unchanged.

Manual checks: existing ESP still tracks smoothly; toggle charge and change tools;
heal while alive; disable automation and verify normal drain/damage; exercise
bookmarks with rejected indoor/vehicle/>100m moves; change loaded world and verify
bookmarks clear; Clover grants, odds restore, and rejection while spinning.
