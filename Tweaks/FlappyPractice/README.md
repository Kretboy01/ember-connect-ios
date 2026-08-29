# Flappy Practice (SpriteKit)

This is Ember Connect's intentionally small example tweak. It adds a compact
`1x` button to the bottom-right of a guest app. In a SpriteKit game, tapping it
switches every visible `SKScene` between its original speed and `0.55x`.

It is useful for Flappy-style SpriteKit games and clones. The original Flappy
Bird and some ports use other engines; those show `No SK` and are left alone.

## What it demonstrates

1. The Tweaks tab copies the bundled `FlappyPractice.dylib` into an
   app-specific `Tweaks/Flappy Practice` folder.
2. The app's settings store that folder name as `LCTweakFolder`.
3. Before launch, Ember Connect patches and signs the dylib with the same local
   certificate used for the guest app.
4. `TweakLoader.dylib` is injected into the guest executable and recursively
   loads enabled dylibs from the selected folder with `dlopen`.
5. The Objective-C constructor above runs inside the guest process and adds the
   practice control.

The tweak uses public UIKit and SpriteKit APIs. It does not patch scores,
purchases, network calls, or game-specific classes.

## Build

The GitHub Actions workflow compiles the arm64 dylib with the iPhoneOS SDK and
embeds it at `EmberTweaks/FlappyPractice.dylib` inside the Ember Connect app.
It also publishes the standalone dylib in the workflow artifact for inspection.
