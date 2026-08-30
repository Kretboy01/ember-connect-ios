# 8BP Offline Lines

An Ember Connect tweak for 8 Ball Pool (`com.miniclip.8ballpoolmult`) that extends the game's native aiming guide in offline/practice games.

The tweak hooks 8 Ball's `UserInfo` aim-ratio getters and scales their original values by 2x, 4x, or 8x. It also asks the game to use its own wide guideline and cue-ball trajectory presentation. It does not draw a separate prediction overlay.

## Offline guard

The effective multiplier is greater than 1 only when the active `GameManager` reports either `isOnOfflineGame` or `isOnPracticeGame`, and also reports that `isOnNetworkedGame` is false. Missing selectors and uncertain state fail closed to the original values.

The small draggable `EC Lines` button is locked during online play. Settings are remembered, but they only become effective again after entering an offline/practice game.

Runtime diagnostics are written to `Library/Caches/EmberConnect/EightBPOfflineLinesStatus.plist` in the guest container.

## Build

```sh
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc -fblocks -dynamiclib Tweaks/EightBPOfflineLines/EightBPOfflineLines.m -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics -install_name @rpath/EightBPOfflineLines.dylib -o EightBPOfflineLines.dylib
```
