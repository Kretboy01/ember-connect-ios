# 8BP Offline Lines

An Ember Connect tweak for 8 Ball Pool (`com.miniclip.8ballpoolmult`) that extends the game's native aiming guide in offline/practice games.

The tweak hooks 8 Ball's `UserInfo` aim-ratio getters and scales their original values by 2x, 4x, or 8x. It also asks the game to use its own wide guideline and cue-ball trajectory presentation. It does not draw a separate prediction overlay.

## Local-match guard

The effective multiplier is greater than 1 unless `GameManager` reports `isOnNetworkedGame`. Pass and Play / hotseat is `isOnLocalGame`, not `isOnOfflineGame`. Practice and Play Offline stay enabled. Online matches stay locked.

Runtime diagnostics are written to `Library/Caches/EmberConnect/EightBPOfflineLinesStatus.plist` in the guest container.

## Build

```sh
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc -fblocks -dynamiclib Tweaks/EightBPOfflineLines/EightBPOfflineLines.m -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics -install_name @rpath/EightBPOfflineLines.dylib -o EightBPOfflineLines.dylib
```
