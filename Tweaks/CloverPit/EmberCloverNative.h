#import "../Shared/EmberRuntime.h"

static void CloverNativeNotice(NSString *message) {
    UIWindow *window = UIApplication.sharedApplication.keyWindow;
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (!top) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clover native tools" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

@interface EmberCloverNative : NSObject {
    void *_gameClass, *_slotClass, *_stateField;
    const void *_instance, *_coinsAdd, *_toBigInteger, *_interestGet, *_interestSet;
    const void *_chanceGet, *_chanceSet, *_seedGet;
    uint32_t _runRoot;
    int _seed;
    BOOL _resolved, _captured;
    float _originalInterest, _originalChance[9];
}
- (void)render:(EmberMenuPanel *)panel;
@end

@implementation EmberCloverNative
- (BOOL)resolve {
    if (_resolved) return YES;
    if (!CloverReady() || !EMRResolve(g_clover_handle) || !EMRRoot || !EMRUnroot || !EMRRootTarget) return NO;
    _gameClass = EMRClass("", "GameplayData");
    _slotClass = EMRClass("", "SlotMachineScript");
    if (!_gameClass || !_slotClass) return NO;
    _stateField = EMRField(_slotClass, "_state");
    _instance = EMRMethod(_gameClass, "get_Instance", 0);
    _seedGet = EMRMethod(_gameClass, "SeedGet", 0);
    _coinsAdd = EMRMethod(_gameClass, "CoinsAdd", 2);
    _interestGet = EMRMethod(_gameClass, "InterestRateGet", 0);
    _interestSet = EMRMethod(_gameClass, "InterestRateSet", 1);
    _chanceGet = EMRMethod(_gameClass, "Symbol_Chance_Get", 3);
    _chanceSet = EMRMethod(_gameClass, "Symbol_Chance_Set", 2);
    // Select System.Numerics.BigInteger.op_Implicit(Int32), not one of its
    // many same-arity numeric overloads or a different library's BigInteger.
    void *big = EMRClass("System.Numerics", "BigInteger");
    if (big && EMRMethods && EMRMethodName && EMRParamCount && EMRParam && EMRTypeEnum) {
        void *iterator = NULL; const void *method;
        while ((method = EMRMethods(big, &iterator))) {
            if (!strcmp(EMRMethodName(method), "op_Implicit") && EMRParamCount(method) == 1 &&
                EMRTypeEnum(EMRParam(method, 0)) == 0x08) { _toBigInteger = method; break; }
        }
    }
    _resolved = YES;
    CloverLog(@"Native v1 resolved coins=%p conversion=%p interest=%p odds=%p", _coinsAdd, _toBigInteger, _interestSet, _chanceSet);
    return YES;
}

- (BOOL)ready {
    if (![self resolve]) return NO;
    // Reading the singleton field first prevents GameplayData.get_Instance
    // from creating/changing run data on the title screen.
    void *slot = EMRSingleton(_slotClass, "instance");
    if (!EMRAlive(slot) || !_stateField) return NO;
    int state = -1;
    EMRFieldGet(slot, _stateField, &state);
    if (state != 3) return NO; // idle; never alter a spin in progress
    void *run = NULL; int seed = 0;
    if (!EMRCall(_instance, NULL, NULL, &run) || !run || !EMRValue(_seedGet, NULL, NULL, &seed, sizeof(seed))) return NO;
    if (!_runRoot || EMRRootTarget(_runRoot) != run || _seed != seed) {
        if (_runRoot) EMRUnroot(_runRoot);
        _runRoot = EMRRoot(run, false); _seed = seed; _captured = NO;
    }
    return _runRoot != 0;
}

- (BOOL)readChance:(int)kind value:(float *)value {
    bool powerups = false, scratch = false;
    void *args[] = {&kind, &powerups, &scratch};
    // GetBasic returns a constant table, NOT the current run's weights.
    // The verified Get(kind,false,false) reads the current spawnChance.
    return EMRValue(_chanceGet, NULL, args, value, sizeof(*value)) && isfinite(*value) && *value >= 0;
}

- (BOOL)capture {
    if (_captured) return YES;
    if (!EMRValue(_interestGet, NULL, NULL, &_originalInterest, sizeof(_originalInterest)) || !isfinite(_originalInterest)) return NO;
    for (int kind = 0; kind < 9; kind++) if (![self readChance:kind value:&_originalChance[kind]]) return NO;
    _captured = YES;
    return YES;
}

- (void)addCoins:(int)amount {
    if (![self ready] || !_toBigInteger || !_coinsAdd) { CloverNativeNotice(@"Load a run and wait for idle reels. Coin conversion must be available."); return; }
    void *conversionArgs[] = {&amount}, *boxed = NULL;
    if (!EMRCall(_toBigInteger, NULL, conversionArgs, &boxed) || !boxed) { CloverNativeNotice(@"Could not create the game's coin value."); return; }
    uint32_t root = EMRRoot(boxed, true);
    if (!root) { CloverNativeNotice(@"Could not retain the coin value safely."); return; }
    bool addToStats = false;
    void *payload = EMRUnbox(boxed);
    void *args[] = {payload, &addToStats};
    BOOL ok = payload && EMRCall(_coinsAdd, NULL, args, NULL);
    EMRUnroot(root);
    CloverLog(@"native coin grant=%d result=%d", amount, ok);
    CloverNativeNotice(ok ? [NSString stringWithFormat:@"Added %d coins to this run.", amount] : @"Coin grant failed.");
}

- (void)setInterest:(float)value {
    if (![self ready] || ![self capture]) { CloverNativeNotice(@"Wait for idle reels in a loaded run."); return; }
    value = MAX(0, MIN(100, value));
    void *args[] = {&value};
    if (!EMRCall(_interestSet, NULL, args, NULL)) CloverNativeNotice(@"Interest control unavailable.");
}

- (void)boost:(int)kind multiplier:(float)multiplier {
    if (![self ready] || ![self capture] || kind < 0 || kind >= 9) { CloverNativeNotice(@"Wait for idle reels in a loaded run."); return; }
    float value = _originalChance[kind] * MAX(1, MIN(20, multiplier));
    if (value <= 0) { CloverNativeNotice(@"This symbol has zero baseline weight; this control does not unlock unavailable symbols."); return; }
    void *args[] = {&kind, &value};
    if (!EMRCall(_chanceSet, NULL, args, NULL)) CloverNativeNotice(@"Symbol weight control unavailable.");
}

- (void)restore {
    if (![self ready] || !_captured) { CloverNativeNotice(@"No captured settings for this idle run. Snapshots do not survive a restart or run change."); return; }
    void *interestArgs[] = {&_originalInterest};
    BOOL ok = EMRCall(_interestSet, NULL, interestArgs, NULL);
    for (int kind = 0; kind < 9; kind++) {
        void *args[] = {&kind, &_originalChance[kind]};
        if (!EMRCall(_chanceSet, NULL, args, NULL)) ok = NO;
    }
    CloverNativeNotice(ok ? @"Restored the interest and symbol weights captured before your first edit. Coin grants are not undone." : @"Some settings could not be restored; snapshot retained for retry.");
    CloverLog(@"native restore result=%d", ok);
}

- (void)render:(EmberMenuPanel *)panel {
    BOOL ready = [self ready];
    [panel setStatus:ready ? @"NATIVE LAB v1  |  REELS IDLE" : @"NATIVE LAB v1  |  WAIT FOR IDLE REELS"];
    [panel setFooter:@"Run edits may be saved. Restore snapshot lasts only for this loaded run/session."];
    __weak typeof(self) weakSelf = self;
    __weak EmberMenuPanel *weakPanel = panel;
    [panel addSection:@"COIN GRANTS  //  CHANGES CURRENT RUN"];
    for (NSNumber *amount in @[@1000, @10000, @100000]) {
        [panel addAction:[NSString stringWithFormat:@"ADD %@ COINS", amount] detail:@"Managed BigInteger; does not inflate earned-coin stats" handler:^{ [weakSelf addCoins:amount.intValue]; }];
    }
    [panel addSection:@"BANK INTEREST"];
    float interest = 7;
    BOOL interestAvailable = ready && EMRValue(_interestGet, NULL, NULL, &interest, sizeof(interest)) && isfinite(interest);
    if (interestAvailable) {
        [panel addSlider:@"INTEREST RATE" value:interest min:0 max:100 format:@"%.0f%%" handler:^(float value) { [weakSelf setInterest:value]; }];
    } else [panel addSection:@"INTEREST UNAVAILABLE UNTIL REELS ARE IDLE"];
    [panel addSection:@"SYMBOL WEIGHTS  //  NOT GUARANTEED RESULTS"];
    NSArray *names = @[@"CLOVER", @"DIAMOND", @"SEVEN"];
    int kinds[] = {2, 4, 6};
    for (int i = 0; i < 3; i++) {
        int kind = kinds[i]; NSString *name = names[i];
        [panel addAction:[NSString stringWithFormat:@"%@ WEIGHT x5", name] detail:@"5x the captured run weight; repeated taps do not stack" handler:^{ [weakSelf boost:kind multiplier:5]; }];
        [panel addAction:[NSString stringWithFormat:@"%@ WEIGHT x20", name] detail:@"Powerups and other game rules still apply" handler:^{ [weakSelf boost:kind multiplier:20]; }];
    }
    [panel addAction:@"RESTORE CAPTURED INTEREST + ODDS" detail:@"Preserves the run's pre-edit values, not factory defaults" handler:^{ [weakSelf restore]; [weakPanel clearRows]; [weakSelf render:weakPanel]; }];
    [panel addAction:@"REFRESH RUNTIME STATUS" detail:nil handler:^{ [weakPanel clearRows]; [weakSelf render:weakPanel]; }];
}
- (void)dealloc { if (_runRoot && EMRUnroot) EMRUnroot(_runRoot); }
@end

static EmberCloverNative *EmberCloverNativeShared(void) {
    static EmberCloverNative *native;
    if (!native) native = [EmberCloverNative new];
    return native;
}
