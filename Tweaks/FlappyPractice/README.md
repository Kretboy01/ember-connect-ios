# Flappy Practice (SpriteKit)

This is Ember Connect's example game-specific tweak. It adds a compact `EC`
button to the bottom-right of Brandon Plank's Flappy Bird. Tapping it opens a
practice menu with:

- coordinated `1x`, `0.75x`, and `0.5x` speed presets;
- wider pipe gaps; and
- ghost mode, which disables crash contacts while leaving score gates active.

The speed presets affect both parts of the game. SpriteKit scene actions slow
the scenery and pipes, while the tweak scales gravity, current bird velocity,
and flap impulses so the bird follows the same arc over the slower timeline.

The implementation deliberately targets the SpriteKit physics categories and
`GameScene` used by `org.brandonplank.flappybird`; it is not advertised as a
generic tweak for unrelated Flappy clones.

## What it demonstrates

1. The Tweaks tab copies the bundled `FlappyPractice.dylib` into an
   app-specific `Tweaks/Flappy Practice` folder.
2. The sample installer finds `org.brandonplank.flappybird` and stores that
   folder name as the app's `LCTweakFolder` automatically.
3. Before launch, Ember Connect patches and signs the dylib with the same local
   certificate used for the guest app.
4. `TweakLoader.dylib` is injected into the guest executable and recursively
   loads enabled dylibs from the selected folder with `dlopen`.
5. The Objective-C constructor above runs inside the guest process and adds the
   practice control.

The tweak uses UIKit and SpriteKit APIs plus a narrow `applyImpulse:` hook for
the bird physics body. It does not patch stored scores, purchases, or network
calls.

For diagnosis it records its last lifecycle state in the guest app's
`Library/Caches/EmberConnect/FlappyPracticeStatus.plist`. This distinguishes a
load/signing problem from a button-attachment or SpriteKit-discovery problem.

## Build

The GitHub Actions workflow compiles the arm64 dylib with the iPhoneOS SDK and
embeds it at `EmberTweaks/FlappyPractice.dylib` inside the Ember Connect app.
It also publishes the standalone dylib in the workflow artifact for inspection.
