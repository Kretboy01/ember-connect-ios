# 8BP Offline Lines

An Ember Connect tweak for 8 Ball Pool (`com.miniclip.8ballpoolmult`) that extends the game's native aiming guide in offline/practice games.

The tweak writes the classic public span (`lowAimRatio=-900`, `highAimRatio=1300`) and keeps `hideGuidelinesMode` off. It does not draw a separate prediction overlay — that crashed Pass and Play load.

## Local-match guard

The effective multiplier is greater than 1 unless `GameManager` reports `isOnNetworkedGame`. Pass and Play / hotseat is `isOnLocalGame`, not `isOnOfflineGame`. Practice and Play Offline stay enabled. Online matches stay locked.

Runtime diagnostics are written to `Library/Caches/EmberConnect/EightBPOfflineLinesStatus.plist` in the guest container.

## Build

```sh
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc -fblocks -dynamiclib Tweaks/EightBPOfflineLines/EightBPOfflineLines.m -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics -install_name @rpath/EightBPOfflineLines.dylib -o EightBPOfflineLines.dylib
```
