# 8BP Offline Lines

Ember Connect tweak for 8 Ball Pool (`com.miniclip.8ballpoolmult`) **56.29.2 / build 5324**.

## Active features

- Colored Cocos `CCSprite` rings on each ball (identity from Ball `number` ivar)
- Extended native VisualGuide aim lines scaled from cue force + table friction
- Offline / Practice / Pass and Play only (`isOnNetworkedGame` stays locked)

## Paused

Multi-cushion rebound prediction and landing rings are **not** in the shipping
dylib. Sources and resume notes live in `paused/` and in `E:\Cli\HANDOFF.md`.

## Local-match guard

Effective guide stays off when `GameManager` reports `isOnNetworkedGame`. Pass
and Play / hotseat is `isOnLocalGame`. Practice and Play Offline stay enabled.

Diagnostics: guest `Documents/EmberEightBallLines.log` and
`Library/Caches/EmberConnect/EightBPOfflineLinesStatus.plist`.

## Pack / install

Bake the dylib into the decrypted IPA by rewriting the last `LC_LOAD_DYLIB`
(libloader → EightBPOfflineLines):

```text
E:\Cli\build_artifacts\8bp-56.29.2\pack_8ball_lines.py
```

After every IPA replace, restore save UUID
`4079AF90-387F-42D5-9499-2FE794B62770` in `LCAppInfo.plist`.

## Build (CI)

Compiled from `EmberMenu.m` + `EightBPOfflineLines.m` in
`.github/workflows/build-ios.yml` (no C++ / no shadow module).
