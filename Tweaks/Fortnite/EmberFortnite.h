// EmberFortnite.h — public interface for the Ember Fortnite dot overlay tweak.
// Only included by EmberFortnite.m.  Keep this header minimal.

#pragma once
#import <Foundation/Foundation.h>

/// Returns YES when the tweak has located the Fortnite binary and verified its
/// build hash.  Drawing is separate; it may be toggled independently.
BOOL EmberFortniteIsReady(void);
