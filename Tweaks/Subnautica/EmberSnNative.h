// Optional gameplay features, verified against the installed metadata v31.
// Kept separate from the user-verified ESP projection/rendering path.
#import "../Shared/EmberRuntime.h"

@interface EmberSnNative : NSObject {
    void *_playerClass, *_inventoryClass, *_energyClass;
    void *_healthField;
    const void *_getTransform, *_getPosition, *_getID, *_setPosition;
    const void *_swimming, *_inside, *_mode, *_cinematic, *_teleporting;
    const void *_healthFraction, *_maxHealth, *_addHealth, *_alive;
    const void *_heldObject, *_getComponent, *_capacity, *_charge, *_addEnergy;
    BOOL _resolved;
    int _playerID;
}
@property BOOL autoCharge;
@property BOOL autoHeal;
@property BOOL showHUD;
@property (nonatomic, strong) UILabel *hud;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSValue *> *bookmarks;
@property (nonatomic, strong) NSValue *returnPosition;
- (void)tickInWindow:(UIWindow *)window;
- (void)render:(EmberMenuPanel *)panel;
- (void)renderAgain:(EmberMenuPanel *)panel;
@end

@implementation EmberSnNative
- (BOOL)resolve {
    if (_resolved) return YES;
    // The base tweak has already resolved UnityFramework; use that loaded handle.
    NSString *path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"UnityFramework.framework/UnityFramework"];
    void *handle = path ? dlopen(path.UTF8String, RTLD_LAZY | RTLD_NOLOAD) : NULL;
    BOOL available = EMRResolve(handle);
    if (handle) dlclose(handle);
    if (!available) return NO;
    _playerClass = EMRClass("", "Player");
    _inventoryClass = EMRClass("", "Inventory");
    _energyClass = EMRClass("", "EnergyMixin");
    void *live = EMRClass("", "LiveMixin");
    void *component = EMRClass("UnityEngine", "Component");
    void *transform = EMRClass("UnityEngine", "Transform");
    void *object = EMRClass("UnityEngine", "Object");
    void *gameObject = EMRClass("UnityEngine", "GameObject");
    if (!_playerClass || !component || !transform || !object) return NO;
    _healthField = EMRField(_playerClass, "liveMixin");
    _getTransform = EMRMethod(component, "get_transform", 0);
    _getPosition = EMRMethod(transform, "get_position", 0);
    _getID = EMRMethod(object, "GetInstanceID", 0);
    _setPosition = EMRMethod(_playerClass, "SetPosition", 1);
    _swimming = EMRMethod(_playerClass, "IsSwimming", 0);
    _inside = EMRMethod(_playerClass, "IsInside", 0);
    _mode = EMRMethod(_playerClass, "GetMode", 0);
    _cinematic = EMRMethod(_playerClass, "get_cinematicModeActive", 0);
    _teleporting = EMRMethod(_playerClass, "get_isWaitingForTeleportation", 0);
    if (live) {
        _healthFraction = EMRMethod(live, "GetHealthFraction", 0);
        _maxHealth = EMRMethod(live, "get_maxHealth", 0);
        _addHealth = EMRMethod(live, "AddHealth", 1);
        _alive = EMRMethod(live, "IsAlive", 0);
    }
    if (_inventoryClass) _heldObject = EMRMethod(_inventoryClass, "GetHeldObject", 0);
    if (gameObject) _getComponent = EMRMethod(gameObject, "GetComponent", 1);
    if (_energyClass) {
        _capacity = EMRMethod(_energyClass, "get_capacity", 0);
        _charge = EMRMethod(_energyClass, "get_charge", 0);
        _addEnergy = EMRMethod(_energyClass, "AddEnergy", 1);
    }
    self.bookmarks = [NSMutableDictionary new];
    _resolved = YES;
    EmberSnLog(@"Native v1 resolved: position=%p health=%p heldEnergy=%p", _setPosition, _addHealth, _addEnergy);
    return YES;
}

- (void *)player {
    if (![self resolve]) return NULL;
    void *player = EMRSingleton(_playerClass, "main");
    int instanceID = 0;
    if (!EMRAlive(player) || !EMRValue(_getID, player, NULL, &instanceID, sizeof(instanceID))) {
        if (_playerID) {
            [self.bookmarks removeAllObjects]; self.returnPosition = nil;
            self.autoCharge = self.autoHeal = NO;
        }
        _playerID = 0;
        return NULL;
    }
    if (_playerID != instanceID) {
        [self.bookmarks removeAllObjects]; self.returnPosition = nil;
        self.autoCharge = self.autoHeal = NO;
        _playerID = instanceID;
    }
    return player;
}

- (BOOL)position:(EmberSnVector3 *)position player:(void *)player {
    void *transform = NULL;
    return player && EMRCall(_getTransform, player, NULL, &transform) && EMRAlive(transform) &&
        EMRValue(_getPosition, transform, NULL, position, sizeof(*position)) &&
        isfinite(position->x) && isfinite(position->y) && isfinite(position->z);
}

- (BOOL)normalPlayer:(void *)player {
    int mode = -1;
    bool cinematic = true, teleporting = true;
    return player && EMRValue(_mode, player, NULL, &mode, sizeof(mode)) && mode == 0 &&
        EMRValue(_cinematic, player, NULL, &cinematic, sizeof(cinematic)) && !cinematic &&
        EMRValue(_teleporting, player, NULL, &teleporting, sizeof(teleporting)) && !teleporting;
}

- (BOOL)openWater:(void *)player {
    bool swimming = false, inside = true;
    return [self normalPlayer:player] &&
        EMRValue(_swimming, player, NULL, &swimming, sizeof(swimming)) && swimming &&
        EMRValue(_inside, player, NULL, &inside, sizeof(inside)) && !inside;
}

- (BOOL)healPlayer:(void *)player {
    if (!_healthField || ![self normalPlayer:player]) return NO;
    void *live = NULL;
    EMRFieldGet(player, _healthField, &live);
    bool alive = false;
    float fraction = 0, maximum = 0;
    if (!EMRAlive(live) || !EMRValue(_alive, live, NULL, &alive, sizeof(alive)) || !alive ||
        !EMRValue(_healthFraction, live, NULL, &fraction, sizeof(fraction)) || !isfinite(fraction) ||
        !EMRValue(_maxHealth, live, NULL, &maximum, sizeof(maximum)) || !isfinite(maximum) || maximum <= 0) return NO;
    if (fraction >= 0.999f) return YES;
    float amount = maximum * (1 - MAX(0.0f, fraction));
    void *args[] = {&amount};
    return EMRCall(_addHealth, live, args, NULL);
}

- (BOOL)chargeHeldTool:(void *)player {
    if (!player || !_inventoryClass || !_energyClass) return NO;
    void *inventory = EMRSingleton(_inventoryClass, "main"), *held = NULL, *energy = NULL;
    if (!EMRAlive(inventory) || !EMRCall(_heldObject, inventory, NULL, &held) || !EMRAlive(held)) return NO;
    void *type = EMRTypeObject(EMRClassType(_energyClass));
    void *args[] = {type};
    if (!type || !EMRCall(_getComponent, held, args, &energy) || !EMRAlive(energy)) return NO;
    float capacity = 0, charge = 0;
    if (!EMRValue(_capacity, energy, NULL, &capacity, sizeof(capacity)) ||
        !EMRValue(_charge, energy, NULL, &charge, sizeof(charge)) ||
        !isfinite(capacity) || !isfinite(charge) || capacity <= 0) return NO;
    float amount = capacity - charge;
    if (amount <= 0.01f) return YES;
    void *energyArgs[] = {&amount};
    bool added = false;
    return EMRValue(_addEnergy, energy, energyArgs, &added, sizeof(added)) && added;
}

- (void)saveSlot:(NSInteger)slot {
    void *player = [self player];
    EmberSnVector3 position;
    if (![self openWater:player] || ![self position:&position player:player]) {
        toast_sn(@"Save bookmarks while freely swimming outside vehicles and bases."); return;
    }
    self.bookmarks[@(slot)] = [NSValue value:&position withObjCType:@encode(EmberSnVector3)];
    toast_sn([NSString stringWithFormat:@"Saved swim bookmark %ld for this loaded world.", (long)slot + 1]);
}

- (void)travelToSlot:(NSInteger)slot {
    // Recheck after confirmation; never retain a player pointer across UI callbacks.
    void *player = [self player];
    NSValue *saved = slot < 0 ? self.returnPosition : self.bookmarks[@(slot)];
    EmberSnVector3 from, to;
    if (!saved || ![self openWater:player] || ![self position:&from player:player]) {
        toast_sn(@"No bookmark here, or you are not freely swimming outside. Bookmarks clear when the world/player changes."); return;
    }
    [saved getValue:&to size:sizeof(to)];
    float distance = sqrtf((to.x-from.x)*(to.x-from.x) + (to.y-from.y)*(to.y-from.y) + (to.z-from.z)*(to.z-from.z));
    if (!isfinite(distance) || distance > 100.0f) {
        toast_sn(@"Bookmark is over 100m away. Swim closer first to avoid a long-distance streaming jump."); return;
    }
    void *args[] = {&to};
    if (!EMRCall(_setPosition, player, args, NULL)) { toast_sn(@"Player movement is unavailable."); return; }
    self.returnPosition = [NSValue value:&from withObjCType:@encode(EmberSnVector3)];
    EmberSnLog(@"Native bookmark move %.1fm (slot=%ld)", distance, (long)slot);
}

- (void)confirmTravel:(NSInteger)slot {
    UIViewController *top = [[EmberSnController sharedController] topViewController];
    if (!top) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Move to swim bookmark?"
        message:@"Short-range experimental movement. The saved spot must still be clear; terrain and objects are not collision-tested. Return jump keeps your previous position."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Move" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf travelToSlot:slot]; }]];
    [top presentViewController:alert animated:YES completion:nil];
}

- (void)tickInWindow:(UIWindow *)window {
    void *player = [self player];
    if (self.autoHeal) [self healPlayer:player];
    if (self.autoCharge && [self normalPlayer:player]) [self chargeHeldTool:player];
    if (!self.showHUD || !window || !player) { [self.hud removeFromSuperview]; self.hud = nil; return; }
    if (!self.hud) {
        self.hud = [UILabel new]; self.hud.userInteractionEnabled = NO;
        self.hud.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightSemibold];
        self.hud.textColor = UIColor.cyanColor;
        self.hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        self.hud.numberOfLines = 2;
    }
    if (self.hud.superview != window) [window addSubview:self.hud];
    UIEdgeInsets inset = window.safeAreaInsets;
    self.hud.frame = CGRectMake(inset.left + 12, CGRectGetHeight(window.bounds) - inset.bottom - 50, 285, 38);
    EmberSnVector3 position;
    if ([self position:&position player:player]) self.hud.text = [NSString stringWithFormat:
        @" XYZ  %.1f  %.1f  %.1f\n Depth ~%.1fm | Charge %@ | Heal %@", position.x, position.y, position.z,
        MAX(0.0f, -position.y), self.autoCharge ? @"ON" : @"OFF", self.autoHeal ? @"ON" : @"OFF"];
    else self.hud.text = @" Position unavailable";
}

- (void)render:(EmberMenuPanel *)panel {
    void *player = [self player];
    [panel setStatus:player ? @"NATIVE MODS v1  |  NO CONSOLE COMMANDS" : @"NATIVE MODS v1  |  LOAD A WORLD FIRST"];
    [panel setFooter:@"Session toggles reset on world change. Refilled health/charge may be saved by the game."];
    __weak typeof(self) weakSelf = self;
    __weak EmberMenuPanel *weakPanel = panel;
    [panel addSection:@"DIRECT GAMEPLAY CONTROLS"];
    [panel addToggle:@"AUTO-CHARGE HELD TOOL" detail:@"Refills equipped tool every 0.5s; requires a battery" enabled:self.autoCharge handler:^(BOOL enabled) {
        if (![weakSelf player]) { toast_sn(@"Load a world first."); [weakSelf renderAgain:weakPanel]; return; }
        weakSelf.autoCharge = enabled;
    }];
    [panel addAction:@"CHARGE HELD TOOL NOW" detail:@"Seaglide, scanner, and other EnergyMixin tools" handler:^{
        if (![weakSelf chargeHeldTool:[weakSelf player]]) toast_sn(@"Hold a powered tool with a battery first, or this tool is unsupported.");
    }];
    [panel addToggle:@"AUTO-HEAL" detail:@"Refills living player every 0.5s; not instant-damage immunity" enabled:self.autoHeal handler:^(BOOL enabled) {
        if (![weakSelf player]) { toast_sn(@"Load a world first."); [weakSelf renderAgain:weakPanel]; return; }
        weakSelf.autoHeal = enabled;
    }];
    [panel addAction:@"HEAL NOW" detail:@"Uses LiveMixin.AddHealth; does not resurrect" handler:^{
        if (![weakSelf healPlayer:[weakSelf player]]) toast_sn(@"Healing unavailable; enter normal gameplay with a living player.");
    }];
    [panel addToggle:@"POSITION / DEPTH HUD" detail:@"Live world coordinates, independent of ESP" enabled:self.showHUD handler:^(BOOL enabled) { weakSelf.showHUD = enabled; }];
    [panel addSection:@"SWIM BOOKMARKS  //  SESSION ONLY, MAX 100m"];
    for (NSInteger slot = 0; slot < 3; slot++) {
        [panel addAction:[NSString stringWithFormat:@"SAVE SLOT %ld", (long)slot + 1] detail:self.bookmarks[@(slot)] ? @"Replace saved swim position" : @"Empty slot" handler:^{ [weakSelf saveSlot:slot]; [weakSelf renderAgain:weakPanel]; }];
        [panel addAction:[NSString stringWithFormat:@"GO TO SLOT %ld", (long)slot + 1] detail:@"Freely swimming only; confirmation required" handler:^{ [weakSelf confirmTravel:slot]; }];
    }
    [panel addAction:@"RETURN JUMP" detail:@"Go back to the position before the last jump" handler:^{ [weakSelf confirmTravel:-1]; }];
    [panel addAction:@"DISABLE NATIVE AUTOMATION" detail:@"Stops charging/healing; hides position HUD" handler:^{
        weakSelf.autoCharge = weakSelf.autoHeal = weakSelf.showHUD = NO;
        [weakSelf.hud removeFromSuperview]; weakSelf.hud = nil;
        [weakSelf renderAgain:weakPanel];
    }];
}
- (void)renderAgain:(EmberMenuPanel *)panel { [panel clearRows]; [self render:panel]; }
@end

static EmberSnNative *EmberSnNativeShared(void) {
    static EmberSnNative *native;
    if (!native) native = [EmberSnNative new];
    return native;
}
