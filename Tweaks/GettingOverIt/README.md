# Ember Getting Over It Tweak

This is a dylib tweak designed to be injected into the Unity game *Getting Over It with Bennett Foddy* on iOS via LiveContainer's TweakLoader.

## What it does
It adds a floating practice panel (UI overlay) offering cheats and practice aids by hooking into the Unity game runtime.

## How it works (Unity IL2CPP Hooking)
Unlike SpriteKit games, Unity iOS games are compiled via IL2CPP. This tweak uses `dlsym` at runtime to find standard IL2CPP API C functions (like `il2cpp_domain_get`, `il2cpp_class_from_name`, `il2cpp_runtime_invoke`).
It then dynamically resolves Unity classes (such as `UnityEngine.Time`, `UnityEngine.Physics2D`) and invokes their methods to manipulate the game state directly from native Objective-C.

## Features
- **Floating Panel UI:** Attaches to the guest app's key window with a drag-able button and expandable panel.
- **Speed Control:** Modifies `UnityEngine.Time.timeScale` to speed up or slow down the game.
- **Gravity Control:** Modifies `UnityEngine.Physics2D.gravity` to change the gravity.
- **Ghost Mode:** Disables collisions for the player.
- **Diagnostics:** Writes status and IL2CPP resolution state to `Library/Caches/EmberConnect/GettingOverItStatus.plist`.

## Graceful Degradation
If IL2CPP API functions cannot be resolved, the tweak will still display the UI overlay but safely disable features that require IL2CPP access. It logs resolution failures to its status plist for debugging purposes.

## Build Instructions
Compile using clang for arm64 iOS:
```bash
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc -fblocks -dynamiclib -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics -install_name @rpath/GettingOverIt.dylib -o GettingOverIt.dylib GettingOverIt.m
```

## Demonstration
This project demonstrates the Ember Connect tweak system interacting with a heavily compiled Unity IL2CPP target, showcasing memory interaction and dynamic C API resolution without linking to external game engine libraries directly.
