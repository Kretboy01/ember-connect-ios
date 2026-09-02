"""Source/metadata contract checks, not a substitute for device gameplay tests.

python tools/verify_native_mods.py --sub-dump PATH --clover-dump PATH
"""
import argparse
from pathlib import Path
import re
import subprocess


def require(condition, message):
    if not condition:
        raise AssertionError(message)
    print(f"PASS: {message}")


def class_body(dump, name):
    match = re.search(r"^public class " + re.escape(name) + r"(?=\s|:)[^\n]*\n\{\n(.*?)^\}", dump, re.M | re.S)
    require(match is not None, f"metadata class {name}")
    return match.group(1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sub-dump", type=Path, required=True)
    parser.add_argument("--clover-dump", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    sub_dump = args.sub_dump.read_text(encoding="utf-8-sig")
    clover_dump = args.clover_dump.read_text(encoding="utf-8-sig")
    for name, signatures in {
        "Player": ["public static Player main;", "public LiveMixin liveMixin;", "public void SetPosition(Vector3 wsPos)",
                   "public bool IsSwimming()", "public bool IsInside()", "public Player.Mode GetMode()",
                   "public bool get_cinematicModeActive()", "public bool get_isWaitingForTeleportation()"],
        "LiveMixin": ["public float GetHealthFraction()", "public float get_maxHealth()", "public float AddHealth(float healthBack)", "public bool IsAlive()"],
        "Inventory": ["public static Inventory main;", "public GameObject GetHeldObject()"],
        "EnergyMixin": ["public float get_charge()", "public float get_capacity()", "public bool AddEnergy(float amount)"],
    }.items():
        body = class_body(sub_dump, name)
        for signature in signatures:
            require(signature in body, f"Subnautica {name}: {signature}")
    body = class_body(clover_dump, "GameplayData")
    for signature in ["public static GameplayData get_Instance()", "public static int SeedGet()",
                      "public static void CoinsAdd(BigInteger value, bool addToStats)",
                      "public static float InterestRateGet()", "public static void InterestRateSet(float value)",
                      "public static float Symbol_Chance_Get(SymbolScript.Kind kind, bool considerPowerups, bool considerScratchAndWin)",
                      "public static void Symbol_Chance_Set(SymbolScript.Kind kind, float value)"]:
        require(signature in body, f"Clover: {signature}")
    slot = class_body(clover_dump, "SlotMachineScript")
    require("public static SlotMachineScript instance;" in slot, "Clover slot singleton")
    require("SlotMachineScript.State _state;" in slot, "Clover idle-state field")
    require("public const SlotMachineScript.State idle = 3;" in clover_dump, "Clover idle enum = 3")
    require("public const Player.Mode Normal = 0;" in sub_dump, "Subnautica normal mode = 0")

    sub_source = (root / "Tweaks/Subnautica/Subnautica.m").read_text(encoding="utf-8")
    baseline = subprocess.check_output(["git", "show", "b5d6c2c:Tweaks/Subnautica/Subnautica.m"], cwd=root, text=True, encoding="utf-8")
    for method, next_method in [("rescanCreatures", "updateESP"), ("updateESP", "espFrame:")]:
        start, end = f"- (void){method}", f"- (void){next_method}"
        require(sub_source.split(start, 1)[1].split(end, 1)[0] == baseline.split(start, 1)[1].split(end, 1)[0],
                f"user-verified ESP {method} unchanged")
    native_sources = [(root / name).read_text(encoding="utf-8") for name in
                      ["Tweaks/Shared/EmberRuntime.h", "Tweaks/Subnautica/EmberSnNative.h", "Tweaks/CloverPit/EmberCloverNative.h"]]
    for forbidden in ["MSHookFunction", "mprotect(", "vm_protect(", "SendConsoleCommand(", "CLOVER_RVA_"]:
        require(all(forbidden not in source for source in native_sources), f"native additions contain no {forbidden}")
    require("distance > 100.0f" in native_sources[1] and "[self openWater:player]" in native_sources[1], "bookmark range/open-water guards present")
    require("EMRRoot(boxed, true)" in native_sources[2] and "EMRUnroot(root)" in native_sources[2], "managed BigInteger argument pinned and released")
    print("Contract checks complete. iOS compilation and manual gameplay tests remain separate checks.")


if __name__ == "__main__":
    main()
