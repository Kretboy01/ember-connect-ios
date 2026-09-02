// Hook-free IL2CPP bridge for optional native features. No executable writes,
// fixed RVAs, or cached game-object pointers. Include once per tweak dylib.
#pragma once
#import <dlfcn.h>
#import <stdint.h>
#import <stdbool.h>
#import <string.h>
#import <math.h>

static void *(*EMRDomain)(void);
static void *(*EMRAttach)(void *);
static const void **(*EMRAssemblies)(void *, size_t *);
static const void *(*EMRImage)(const void *);
static void *(*EMRClassFromName)(const void *, const char *, const char *);
static const void *(*EMRMethod)(void *, const char *, int);
static const void *(*EMRMethods)(void *, void **);
static const char *(*EMRMethodName)(const void *);
static uint32_t (*EMRParamCount)(const void *);
static const void *(*EMRParam)(const void *, uint32_t);
static int (*EMRTypeEnum)(const void *);
static void *(*EMRInvoke)(const void *, void *, void **, void **);
static void *(*EMRUnbox)(void *);
static void *(*EMRField)(void *, const char *);
static void (*EMRStaticGet)(void *, void *);
static void (*EMRFieldGet)(void *, void *, void *);
static const void *(*EMRClassType)(void *);
static void *(*EMRTypeObject)(const void *);
static uint32_t (*EMRRoot)(void *, bool);
static void (*EMRUnroot)(uint32_t);
static void *(*EMRRootTarget)(uint32_t);

static BOOL EMRResolve(void *handle) {
#define EMR_LOAD(slot, name) if (!slot) { slot = (__typeof__(slot))dlsym(RTLD_DEFAULT, name); if (!slot && handle) slot = (__typeof__(slot))dlsym(handle, name); }
    EMR_LOAD(EMRDomain, "il2cpp_domain_get")
    EMR_LOAD(EMRAttach, "il2cpp_thread_attach")
    EMR_LOAD(EMRAssemblies, "il2cpp_domain_get_assemblies")
    EMR_LOAD(EMRImage, "il2cpp_assembly_get_image")
    EMR_LOAD(EMRClassFromName, "il2cpp_class_from_name")
    EMR_LOAD(EMRMethod, "il2cpp_class_get_method_from_name")
    EMR_LOAD(EMRMethods, "il2cpp_class_get_methods")
    EMR_LOAD(EMRMethodName, "il2cpp_method_get_name")
    EMR_LOAD(EMRParamCount, "il2cpp_method_get_param_count")
    EMR_LOAD(EMRParam, "il2cpp_method_get_param")
    EMR_LOAD(EMRTypeEnum, "il2cpp_type_get_type")
    EMR_LOAD(EMRInvoke, "il2cpp_runtime_invoke")
    EMR_LOAD(EMRUnbox, "il2cpp_object_unbox")
    EMR_LOAD(EMRField, "il2cpp_class_get_field_from_name")
    EMR_LOAD(EMRStaticGet, "il2cpp_field_static_get_value")
    EMR_LOAD(EMRFieldGet, "il2cpp_field_get_value")
    EMR_LOAD(EMRClassType, "il2cpp_class_get_type")
    EMR_LOAD(EMRTypeObject, "il2cpp_type_get_object")
    EMR_LOAD(EMRRoot, "il2cpp_gchandle_new")
    EMR_LOAD(EMRUnroot, "il2cpp_gchandle_free")
    EMR_LOAD(EMRRootTarget, "il2cpp_gchandle_get_target")
#undef EMR_LOAD
    if (!EMRDomain || !EMRAttach || !EMRAssemblies || !EMRImage ||
        !EMRClassFromName || !EMRMethod || !EMRInvoke || !EMRUnbox ||
        !EMRField || !EMRStaticGet || !EMRFieldGet || !EMRClassType || !EMRTypeObject) return NO;
    void *domain = EMRDomain();
    if (!domain) return NO;
    EMRAttach(domain);
    return YES;
}

static void *EMRClass(const char *space, const char *name) {
    size_t count = 0;
    const void **assemblies = EMRAssemblies(EMRDomain(), &count);
    for (size_t i = 0; assemblies && i < count; i++) {
        const void *image = EMRImage(assemblies[i]);
        void *klass = image ? EMRClassFromName(image, space, name) : NULL;
        if (klass) return klass;
    }
    return NULL;
}

static BOOL EMRCall(const void *method, void *object, void **args, void **result) {
    if (result) *result = NULL;
    if (!method || !EMRInvoke) return NO;
    void *exception = NULL;
    void *value = EMRInvoke(method, object, args, &exception);
    if (exception) return NO;
    if (result) *result = value;
    return YES;
}

static BOOL EMRValue(const void *method, void *object, void **args, void *out, size_t size) {
    void *boxed = NULL;
    if (!EMRCall(method, object, args, &boxed) || !boxed) return NO;
    void *payload = EMRUnbox(boxed);
    if (!payload) return NO;
    memcpy(out, payload, size);
    return YES;
}

static void *EMRSingleton(void *klass, const char *name) {
    void *field = klass ? EMRField(klass, name) : NULL;
    void *object = NULL;
    if (field) EMRStaticGet(field, &object);
    return object;
}

static BOOL EMRAlive(void *object) {
    static const void *valid;
    if (!valid) { void *klass = EMRClass("UnityEngine", "Object"); if (klass) valid = EMRMethod(klass, "op_Implicit", 1); }
    bool alive = false;
    void *args[] = {object};
    return object && EMRValue(valid, NULL, args, &alive, sizeof(alive)) && alive;
}
