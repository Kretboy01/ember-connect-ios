# 8BP Offline Lines

An Ember Connect tweak for 8 Ball Pool (`com.miniclip.8ballpoolmult`) **56.29.2 / build 5324**.

## Active features

- Persistent Cocos ball rings tinted from each Ball's real number
- Native VisualGuide length derived from cue force, pull power, collision transfer, and table friction
- Detached native-physics prediction for ball collisions, cushion rebounds, pockets, and final positions
- Same-colour destination rings that disappear when the real ball arrives
- Shared Ember menu toggles for guide, rebounds, and destination rings

## Local-match guard

The feature is disabled whenever `GameManager` reports `isOnNetworkedGame`.
Pass and Play / hotseat, Practice, and Play Offline remain enabled.

Runtime diagnostics are written to `Documents/EmberEightBallLines.log` and
`Library/Caches/EmberConnect/EightBPOfflineLinesStatus.plist` in the guest container.

## Build

```sh
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
  -fobjc-arc -fblocks -dynamiclib \
  Tweaks/Shared/EmberMenu.m \
  Tweaks/EightBPOfflineLines/EightBPShadowPhysics.mm \
  Tweaks/EightBPOfflineLines/EightBPOfflineLines.m \
  -framework Foundation -framework UIKit -framework QuartzCore \
  -framework CoreGraphics -lc++ \
  -install_name @rpath/EightBPOfflineLines.dylib \
  -o EightBPOfflineLines.dylib
```
