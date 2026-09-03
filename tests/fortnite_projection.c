#include "../Tweaks/Fortnite/EmberFortniteProjection.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static void near(double actual, double expected, double tolerance) {
    assert(fabs(actual - expected) <= tolerance);
}

int main(void) {
    near(EmberFnRenderFovDegrees(1.0, 80.0), 90.0, 0.001);
    near(EmberFnRenderFovDegrees(0.0, 80.0), 80.0, 0.001);
    near(EmberFnRenderFovDegrees(NAN, 75.0), 75.0, 0.001);

    const EmberFnProjectionVec3 origin = {0, 0, 0};
    double x = 0, y = 0;

    // Player right of aim is right of screen, and aiming at that player centers it.
    EmberFnProjectionVec3 player = {1000, 100, 0};
    assert(EmberFnProjectWorldPoint(player, origin, 0, 0, 0, 90, 1, 1000, 500, &x, &y));
    assert(x > 500); near(y, 250, 0.001);
    assert(EmberFnProjectWorldPoint(player, origin, 0, atan2(100, 1000) * 180.0 / 3.14159265358979323846,
                                    0, 90, 1, 1000, 500, &x, &y));
    near(x, 500, 0.001); near(y, 250, 0.001);

    // Turning farther right leaves the player on the left, exactly like rendered view.
    assert(EmberFnProjectWorldPoint(player, origin, 0, 20, 0, 90, 1, 1000, 500, &x, &y));
    assert(x < 500);

    // Aiming up at a raised player centers vertically; UIKit y grows downward.
    player = (EmberFnProjectionVec3){1000, 0, 100};
    assert(EmberFnProjectWorldPoint(player, origin, atan2(100, 1000) * 180.0 / 3.14159265358979323846,
                                    0, 0, 90, 1, 1000, 500, &x, &y));
    near(x, 500, 0.001); near(y, 250, 0.001);
    assert(EmberFnProjectWorldPoint(player, origin, 0, 0, 0, 90, 1, 1000, 500, &x, &y));
    assert(y < 250);

    assert(!EmberFnProjectWorldPoint((EmberFnProjectionVec3){-10,0,0}, origin,
                                     0,0,0,90,1,1000,500,&x,&y));

    // MaintainYFOV must use the height-derived focal length in landscape.
    player = (EmberFnProjectionVec3){1000, 100, 0};
    assert(EmberFnProjectWorldPoint(player, origin, 0, 0, 0, 90, 1, 1000, 500, &x, &y));
    near(x, 550, 0.001);
    assert(EmberFnProjectWorldPoint(player, origin, 0, 0, 0, 90, 0, 1000, 500, &x, &y));
    near(x, 525, 0.001);
    puts("PASS Fortnite projection: yaw/pitch tracking and handedness");
    return 0;
}
