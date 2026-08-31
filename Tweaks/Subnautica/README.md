# Subnautica tweak (Ember Connect)

IL2CPP mod for the Subnautica iOS guest. Unlike trial-and-error memory patches,
it drives the game's **own developer console**:
`DevConsole.SendConsoleCommand(string)` dispatches to the same
`OnConsoleCommand_*` handlers the built-in console uses, so every feature is
exactly the developers' implementation.

## Features

- Refill Oxygen (`oxygen`)
- Restore Food & Water (`survival`)
- Set Day / Night (`day`, `night`)
- Toggles: no damage (`nodamage`), no crafting costs (`nocost`), fast growth
  (`fastgrow`), fast scan (`fastscan`), fast build (`fastbuild`), fast swim
  (`fastswim`), invisible (`invisible`)
- Unlock all blueprints (`unlockall`)
- Game speed 0.5x–3x (`UnityEngine.Time::set_timeScale` icall)

## Requirements

- IL2CPP runtime: Subnautica ships `UnityFramework.framework`, which exports
  the full `il2cpp_*` API — resolved with retries until Unity finishes
  loading.
- The floating **SN Tools** button appears once the guest reaches the main
  scene; it reads "SN Waiting…" until the runtime resolves.

## Diagnostics

`Documents/EmberConnect/Subnautica-diag.log` in the guest container records
every resolution and console dispatch, for remote debugging via the desktop
Files tab.
