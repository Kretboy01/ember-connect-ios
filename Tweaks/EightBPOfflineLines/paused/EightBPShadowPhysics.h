#ifndef EIGHT_BP_SHADOW_PHYSICS_H
#define EIGHT_BP_SHADOW_PHYSICS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    EightBPShadowMaxBalls = 20,
    EightBPShadowMaxPathPoints = 64,
    EightBPShadowStatusCapacity = 192
};

typedef struct EightBPShadowPoint {
    double x;
    double y;
} EightBPShadowPoint;

typedef struct EightBPShadowBallPrediction {
    const void *liveBall;
    uint32_t number;
    bool valid;
    bool potted;
    uint16_t pathPointCount;
    EightBPShadowPoint finalPosition;
    EightBPShadowPoint path[EightBPShadowMaxPathPoints];
} EightBPShadowBallPrediction;

typedef struct EightBPShadowPrediction {
    bool valid;
    uint16_t ballCount;
    uint16_t simulatedFrames;
    uint16_t resolvedEvents;
    EightBPShadowBallPrediction balls[EightBPShadowMaxBalls];
    char status[EightBPShadowStatusCapacity];
} EightBPShadowPrediction;

typedef void (*EightBPShadowLogCallback)(const char *message, void *context);

void EightBPShadowSetLogCallback(EightBPShadowLogCallback callback, void *context);
const char *EightBPShadowLastStatus(void);

#ifdef __OBJC__
@class NSObject;

bool EightBPShadowValidateRuntime(NSObject *table,
                                  NSObject *cueBall,
                                  const void *visualGuide,
                                  const double friction[7],
                                  char status[EightBPShadowStatusCapacity]);

bool EightBPShadowPredict(NSObject *table,
                         NSObject *cueBall,
                         const void *visualGuide,
                         double initialSpeed,
                         const double friction[7],
                         EightBPShadowPrediction *prediction);
#endif

#ifdef __cplusplus
}
#endif

#endif
