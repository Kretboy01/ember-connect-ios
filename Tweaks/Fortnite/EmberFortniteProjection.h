#ifndef EMBER_FORTNITE_PROJECTION_H
#define EMBER_FORTNITE_PROJECTION_H

#include <math.h>
#include <stdbool.h>

typedef struct { double x, y, z; } EmberFnProjectionVec3;

// Unreal FRotationMatrix world-to-screen projection. Rotation and horizontal
// FOV are degrees; UIKit's screen origin is at the top left.
static inline bool EmberFnProjectWorldPoint(EmberFnProjectionVec3 world,
                                             EmberFnProjectionVec3 camera,
                                             double pitch,
                                             double yaw,
                                             double roll,
                                             double horizontalFov,
                                             double width,
                                             double height,
                                             double *screenX,
                                             double *screenY) {
    if (!screenX || !screenY || !isfinite(width) || !isfinite(height) ||
        width <= 1.0 || height <= 1.0 || !isfinite(horizontalFov) ||
        horizontalFov <= 1.0 || horizontalFov >= 179.0) return false;

    const double radians = 3.14159265358979323846 / 180.0;
    const double sp = sin(pitch * radians), cp = cos(pitch * radians);
    const double sy = sin(yaw * radians),   cy = cos(yaw * radians);
    const double sr = sin(roll * radians),  cr = cos(roll * radians);
    const double dx = world.x - camera.x;
    const double dy = world.y - camera.y;
    const double dz = world.z - camera.z;

    const double forwardX = cp * cy, forwardY = cp * sy, forwardZ = sp;
    const double rightX = sr * sp * cy - cr * sy;
    const double rightY = sr * sp * sy + cr * cy;
    const double rightZ = -sr * cp;
    const double upX = -(cr * sp * cy + sr * sy);
    const double upY = cy * sr - cr * sp * sy;
    const double upZ = cr * cp;

    const double viewX = dx * rightX + dy * rightY + dz * rightZ;
    const double viewY = dx * upX + dy * upY + dz * upZ;
    const double depth = dx * forwardX + dy * forwardY + dz * forwardZ;
    if (!isfinite(depth) || depth <= 1.0) return false;

    const double tangent = tan(horizontalFov * radians * 0.5);
    if (!isfinite(tangent) || tangent <= 1e-6) return false;
    const double focal = (width * 0.5) / tangent;
    *screenX = width * 0.5 + viewX * focal / depth;
    *screenY = height * 0.5 - viewY * focal / depth;
    return isfinite(*screenX) && isfinite(*screenY);
}

#endif
