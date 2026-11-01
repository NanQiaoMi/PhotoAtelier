#define _DARWIN_C_SOURCE
#include "CLensfunBridge.h"

#include <dlfcn.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <lensfun/lensfun.h>

typedef struct LFBProfileRecord {
    LFBProfileInfo public_info;
    char *identifier_storage;
    char *name_storage;
    char *maker_storage;
    char *maker_search;
    char *model_search;
    const lfLens *lens;
} LFBProfileRecord;

typedef struct LFBApi {
    void *library;
    lfDatabase *(*db_new)(void);
    void (*db_destroy)(lfDatabase *db);
    int (*db_load_directory)(lfDatabase *db, const char *dirname);
    const lfCamera **(*db_find_cameras)(const lfDatabase *db,
                                        const char *maker,
                                        const char *model);
    const lfLens **(*db_find_lenses_hd)(const lfDatabase *db,
                                        const lfCamera *camera,
                                        const char *maker,
                                        const char *lens,
                                        int sflags);
    const lfLens *const *(*db_get_lenses)(const lfDatabase *db);
    void (*free_memory)(void *data);
    const char *(*mlstr_get)(const lfMLstr str);
    lfModifier *(*modifier_new)(const lfLens *lens, float crop, int width, int height);
    void (*modifier_destroy)(lfModifier *modifier);
    int (*modifier_initialize)(lfModifier *modifier, const lfLens *lens,
                               lfPixelFormat format, float focal, float aperture,
                               float distance, float scale, lfLensType target_geometry,
                               int flags, int reverse);
    float (*modifier_get_auto_scale)(lfModifier *modifier, int reverse);
    int (*modifier_apply_geometry_distortion)(lfModifier *modifier,
                                              float xu, float yu,
                                              int width, int height,
                                              float *result);
} LFBApi;

struct LFBBridge {
    LFBApi api;
    lfDatabase *database;
    LFBProfileRecord *profiles;
    size_t profile_count;
    char *availability;
    pthread_mutex_t database_lock;
    int mutex_initialized;
};

typedef lfDatabase *(*LFBDBNewFn)(void);
typedef void (*LFBDBDestroyFn)(lfDatabase *db);
typedef int (*LFBDBLoadDirectoryFn)(lfDatabase *db, const char *dirname);
typedef const lfCamera **(*LFBDBFindCamerasFn)(const lfDatabase *db,
                                               const char *maker,
                                               const char *model);
typedef const lfLens **(*LFBDBFindLensesHDFn)(const lfDatabase *db,
                                              const lfCamera *camera,
                                              const char *maker,
                                              const char *lens,
                                              int sflags);
typedef const lfLens *const *(*LFBDBGetLensesFn)(const lfDatabase *db);
typedef void (*LFBFreeFn)(void *data);
typedef const char *(*LFBMLstrGetFn)(const lfMLstr str);
typedef lfModifier *(*LFBModifierNewFn)(const lfLens *lens, float crop,
                                         int width, int height);
typedef void (*LFBModifierDestroyFn)(lfModifier *modifier);
typedef int (*LFBModifierInitializeFn)(lfModifier *modifier, const lfLens *lens,
                                        lfPixelFormat format, float focal,
                                        float aperture, float distance, float scale,
                                        lfLensType target_geometry, int flags,
                                        int reverse);
typedef float (*LFBModifierGetAutoScaleFn)(lfModifier *modifier, int reverse);
typedef int (*LFBModifierApplyGeometryFn)(lfModifier *modifier,
                                          float xu, float yu,
                                          int width, int height,
                                          float *result);

static void lfb_set_error(char *buffer, size_t capacity, const char *format, ...)
{
    if (buffer == NULL || capacity == 0) {
        return;
    }
    va_list arguments;
    va_start(arguments, format);
    (void)vsnprintf(buffer, capacity, format, arguments);
    va_end(arguments);
    buffer[capacity - 1] = '\0';
}

static char *lfb_strdup(const char *value)
{
    if (value == NULL) {
        return NULL;
    }
    size_t length = strlen(value);
    char *copy = (char *)malloc(length + 1);
    if (copy != NULL) {
        memcpy(copy, value, length + 1);
    }
    return copy;
}

static const char *lfb_default_ml_string(const lfMLstr value)
{
    return value != NULL && value[0] != '\0' ? value : NULL;
}

static int lfb_join_path(char *output, size_t capacity,
                         const char *root, const char *suffix)
{
    if (output == NULL || capacity == 0 || root == NULL || suffix == NULL) {
        return 0;
    }
    size_t root_length = strlen(root);
    const char *separator = root_length > 0 && root[root_length - 1] == '/' ? "" : "/";
    int written = snprintf(output, capacity, "%s%s%s", root, separator, suffix);
    return written >= 0 && (size_t)written < capacity;
}

static int lfb_is_readable(const char *path)
{
    return path != NULL && access(path, R_OK) == 0;
}

static int lfb_is_directory(const char *path)
{
    struct stat information;
    return path != NULL && stat(path, &information) == 0 && S_ISDIR(information.st_mode);
}

static int lfb_resolve_paths(const char *project_root,
                             const char *bundle_frameworks_root,
                             const char *bundle_resources_root,
                             char *library_path,
                             size_t library_capacity,
                             char *database_path,
                             size_t database_capacity)
{
    if (project_root != NULL && project_root[0] != '\0') {
        char dependency_root[PATH_MAX];
        if (lfb_join_path(dependency_root, sizeof(dependency_root), project_root,
                          ".dependencies/lensfun")) {
            (void)lfb_join_path(library_path, library_capacity, dependency_root,
                                "lib/liblensfun.0.3.4.dylib");
            (void)lfb_join_path(database_path, database_capacity, dependency_root, "db");
            if (lfb_is_readable(library_path) && lfb_is_directory(database_path)) {
                return 1;
            }
        }
    }

    if (bundle_frameworks_root != NULL && bundle_frameworks_root[0] != '\0' &&
        bundle_resources_root != NULL && bundle_resources_root[0] != '\0') {
        (void)lfb_join_path(library_path, library_capacity, bundle_frameworks_root,
                            "liblensfun.0.3.4.dylib");
        char lensfun_resources[PATH_MAX];
        if (lfb_join_path(lensfun_resources, sizeof(lensfun_resources),
                          bundle_resources_root, "Lensfun")) {
            (void)lfb_join_path(database_path, database_capacity, lensfun_resources, "db");
            if (lfb_is_readable(library_path) && lfb_is_directory(database_path)) {
                return 1;
            }
        }
    }
    return 0;
}

#define LFB_LOAD_SYMBOL(api, field, symbol_name, failure_label)                 \
    do {                                                                         \
        void *symbol_address = dlsym((api)->library, (symbol_name));              \
        if (symbol_address == NULL || sizeof((api)->field) != sizeof(symbol_address)) { \
            lfb_set_error(error_buffer, error_buffer_capacity,                    \
                          "Lensfun 0.3.4 缺少符号 %s。", (symbol_name));          \
            goto failure_label;                                                  \
        }                                                                        \
        memcpy(&(api)->field, &symbol_address, sizeof((api)->field));             \
    } while (0)

static uint64_t lfb_hash_bytes(uint64_t hash, const void *bytes, size_t length)
{
    const unsigned char *cursor = (const unsigned char *)bytes;
    for (size_t index = 0; index < length; ++index) {
        hash ^= (uint64_t)cursor[index];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static uint64_t lfb_hash_string(uint64_t hash, const char *value)
{
    if (value == NULL) {
        const unsigned char absent = 0xff;
        return lfb_hash_bytes(hash, &absent, sizeof(absent));
    }
    hash = lfb_hash_bytes(hash, value, strlen(value));
    const unsigned char terminator = 0;
    return lfb_hash_bytes(hash, &terminator, sizeof(terminator));
}

static uint64_t lfb_profile_hash(const lfLens *lens)
{
    uint64_t hash = UINT64_C(14695981039346656037);
    hash = lfb_hash_string(hash, lfb_default_ml_string(lens->Maker));
    hash = lfb_hash_string(hash, lfb_default_ml_string(lens->Model));
    hash = lfb_hash_bytes(hash, &lens->MinFocal, sizeof(lens->MinFocal));
    hash = lfb_hash_bytes(hash, &lens->MaxFocal, sizeof(lens->MaxFocal));
    hash = lfb_hash_bytes(hash, &lens->CropFactor, sizeof(lens->CropFactor));
    hash = lfb_hash_bytes(hash, &lens->AspectRatio, sizeof(lens->AspectRatio));
    hash = lfb_hash_bytes(hash, &lens->Type, sizeof(lens->Type));
    if (lens->CalibDistortion != NULL) {
        for (size_t index = 0;
             index < 100000 && lens->CalibDistortion[index] != NULL;
             ++index) {
            const lfLensCalibDistortion *calibration = lens->CalibDistortion[index];
            hash = lfb_hash_bytes(hash, &calibration->Model, sizeof(calibration->Model));
            hash = lfb_hash_bytes(hash, &calibration->Focal, sizeof(calibration->Focal));
            hash = lfb_hash_bytes(hash, calibration->Terms, sizeof(calibration->Terms));
        }
    }
    if (lens->Mounts != NULL) {
        for (size_t index = 0; lens->Mounts[index] != NULL; ++index) {
            hash = lfb_hash_string(hash, lens->Mounts[index]);
        }
    }
    return hash;
}

static size_t lfb_count_profiles(const lfLens *const *lenses)
{
    size_t count = 0;
    if (lenses == NULL) {
        return 0;
    }
    while (count < 100000 && lenses[count] != NULL) {
        ++count;
    }
    return count;
}

static int lfb_prepare_profiles(LFBBridge *bridge, char *error_buffer,
                                size_t error_buffer_capacity)
{
    const lfLens *const *lenses = bridge->api.db_get_lenses(bridge->database);
    size_t total = lfb_count_profiles(lenses);
    if (total == 0) {
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "Lensfun 数据库已加载，但没有镜头 profile。");
        return 0;
    }
    if (total > SIZE_MAX / sizeof(LFBProfileRecord)) {
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "Lensfun 镜头 profile 数量超出可用内存范围。");
        return 0;
    }

    LFBProfileRecord *records = (LFBProfileRecord *)calloc(total, sizeof(*records));
    if (records == NULL) {
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "无法为 Lensfun 镜头列表分配内存。");
        return 0;
    }

    size_t stored = 0;
    for (size_t index = 0; index < total; ++index) {
        const lfLens *lens = lenses[index];
        const char *maker_search = lens == NULL ? NULL : lfb_default_ml_string(lens->Maker);
        const char *model_search = lens == NULL ? NULL : lfb_default_ml_string(lens->Model);
        if (maker_search == NULL || model_search == NULL) {
            continue;
        }
        const char *localized_maker = bridge->api.mlstr_get(lens->Maker);
        const char *localized_model = bridge->api.mlstr_get(lens->Model);
        if (localized_maker == NULL || localized_model == NULL) {
            continue;
        }
        LFBProfileRecord *record = &records[stored];
        record->maker_search = lfb_strdup(maker_search);
        record->model_search = lfb_strdup(model_search);
        record->maker_storage = lfb_strdup(localized_maker);
        record->name_storage = lfb_strdup(localized_model);
        record->lens = lens;
        char identifier[96];
        uint64_t hash = lfb_profile_hash(lens);
        (void)snprintf(identifier, sizeof(identifier), "lensfun-0.3.4-%016" PRIx64,
                       hash);
        for (size_t prior = 0; prior < stored; ++prior) {
            if (strcmp(records[prior].identifier_storage, identifier) == 0) {
                (void)snprintf(identifier, sizeof(identifier),
                               "lensfun-0.3.4-%016" PRIx64 "-%zu", hash, index);
                break;
            }
        }
        record->identifier_storage = lfb_strdup(identifier);
        if (record->maker_search == NULL || record->model_search == NULL ||
            record->maker_storage == NULL || record->name_storage == NULL ||
            record->identifier_storage == NULL) {
            for (size_t cleanup = 0; cleanup <= stored; ++cleanup) {
                free(records[cleanup].identifier_storage);
                free(records[cleanup].name_storage);
                free(records[cleanup].maker_storage);
                free(records[cleanup].maker_search);
                free(records[cleanup].model_search);
            }
            free(records);
            lfb_set_error(error_buffer, error_buffer_capacity,
                          "无法保存 Lensfun 镜头 profile 列表。");
            return 0;
        }
        record->public_info.identifier = record->identifier_storage;
        record->public_info.name = record->name_storage;
        record->public_info.maker = record->maker_storage;
        record->public_info.crop_factor = lens->CropFactor;
        ++stored;
    }

    if (stored == 0) {
        free(records);
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "Lensfun 数据库没有带有名称的镜头 profile。");
        return 0;
    }
    bridge->profiles = records;
    bridge->profile_count = stored;
    return 1;
}

static void lfb_free_profiles(LFBBridge *bridge)
{
    if (bridge == NULL || bridge->profiles == NULL) {
        return;
    }
    for (size_t index = 0; index < bridge->profile_count; ++index) {
        free(bridge->profiles[index].identifier_storage);
        free(bridge->profiles[index].name_storage);
        free(bridge->profiles[index].maker_storage);
        free(bridge->profiles[index].maker_search);
        free(bridge->profiles[index].model_search);
    }
    free(bridge->profiles);
    bridge->profiles = NULL;
    bridge->profile_count = 0;
}

static LFBProfileRecord *lfb_find_profile(LFBBridge *bridge, const char *identifier)
{
    if (bridge == NULL || identifier == NULL) {
        return NULL;
    }
    for (size_t index = 0; index < bridge->profile_count; ++index) {
        if (strcmp(bridge->profiles[index].identifier_storage, identifier) == 0) {
            return &bridge->profiles[index];
        }
    }
    return NULL;
}

static size_t lfb_count_camera_array(const lfCamera **array)
{
    size_t count = 0;
    if (array == NULL) {
        return 0;
    }
    while (count < 100000 && array[count] != NULL) {
        ++count;
    }
    return count;
}

static size_t lfb_count_lens_array(const lfLens **array)
{
    size_t count = 0;
    if (array == NULL) {
        return 0;
    }
    while (count < 100000 && array[count] != NULL) {
        ++count;
    }
    return count;
}

static const lfCamera *lfb_find_unique_camera(LFBBridge *bridge,
                                               const char *maker,
                                               const char *model,
                                               LFBStatus *status)
{
    const lfCamera **matches = bridge->api.db_find_cameras(bridge->database, maker, model);
    size_t count = lfb_count_camera_array(matches);
    const lfCamera *result = NULL;
    if (count == 0) {
        *status = LFB_STATUS_NO_MATCH;
    } else if (count > 1) {
        *status = LFB_STATUS_AMBIGUOUS;
    } else {
        result = matches[0];
    }
    if (matches != NULL) {
        bridge->api.free_memory((void *)matches);
    }
    return result;
}

static int lfb_lens_is_compatible(LFBBridge *bridge, const lfCamera *camera,
                                 LFBProfileRecord *profile)
{
    const lfLens **matches = bridge->api.db_find_lenses_hd(
        bridge->database, camera, profile->maker_search, profile->model_search, 0);
    size_t count = lfb_count_lens_array(matches);
    int compatible = 0;
    for (size_t index = 0; index < count; ++index) {
        if (matches[index] == profile->lens) {
            compatible = 1;
            break;
        }
    }
    if (matches != NULL) {
        bridge->api.free_memory((void *)matches);
    }
    return compatible;
}

static int lfb_finite_range(double value, double minimum, double maximum)
{
    return isfinite(value) && value >= minimum && value <= maximum;
}

LFBBridge *lfb_create(const char *project_root,
                      const char *bundle_frameworks_root,
                      const char *bundle_resources_root,
                      char *error_buffer,
                      size_t error_buffer_capacity)
{
    if (error_buffer != NULL && error_buffer_capacity > 0) {
        error_buffer[0] = '\0';
    }
    char library_path[PATH_MAX] = {0};
    char database_path[PATH_MAX] = {0};
    if (!lfb_resolve_paths(project_root, bundle_frameworks_root,
                           bundle_resources_root, library_path, sizeof(library_path),
                           database_path, sizeof(database_path))) {
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "找不到 Lensfun 0.3.4 运行库或离线数据库。");
        return NULL;
    }

    LFBBridge *bridge = (LFBBridge *)calloc(1, sizeof(*bridge));
    if (bridge == NULL) {
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "无法为 Lensfun bridge 分配内存。");
        return NULL;
    }
    if (pthread_mutex_init(&bridge->database_lock, NULL) != 0) {
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "无法初始化 Lensfun 数据库锁。");
        free(bridge);
        return NULL;
    }
    bridge->mutex_initialized = 1;

    bridge->api.library = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
    if (bridge->api.library == NULL) {
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "无法加载 Lensfun 0.3.4：%s", dlerror());
        goto failure;
    }

    LFB_LOAD_SYMBOL(&bridge->api, db_new, "lf_db_new", failure);
    LFB_LOAD_SYMBOL(&bridge->api, db_destroy, "lf_db_destroy", failure);
    LFB_LOAD_SYMBOL(&bridge->api, db_load_directory, "lf_db_load_directory", failure);
    LFB_LOAD_SYMBOL(&bridge->api, db_find_cameras, "lf_db_find_cameras", failure);
    LFB_LOAD_SYMBOL(&bridge->api, db_find_lenses_hd, "lf_db_find_lenses_hd", failure);
    LFB_LOAD_SYMBOL(&bridge->api, db_get_lenses, "lf_db_get_lenses", failure);
    LFB_LOAD_SYMBOL(&bridge->api, free_memory, "lf_free", failure);
    LFB_LOAD_SYMBOL(&bridge->api, mlstr_get, "lf_mlstr_get", failure);
    LFB_LOAD_SYMBOL(&bridge->api, modifier_new, "lf_modifier_new", failure);
    LFB_LOAD_SYMBOL(&bridge->api, modifier_destroy, "lf_modifier_destroy", failure);
    LFB_LOAD_SYMBOL(&bridge->api, modifier_initialize, "lf_modifier_initialize", failure);
    LFB_LOAD_SYMBOL(&bridge->api, modifier_get_auto_scale,
                    "lf_modifier_get_auto_scale", failure);
    LFB_LOAD_SYMBOL(&bridge->api, modifier_apply_geometry_distortion,
                    "lf_modifier_apply_geometry_distortion", failure);

    bridge->database = bridge->api.db_new();
    if (bridge->database == NULL) {
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "Lensfun 无法创建镜头数据库对象。");
        goto failure;
    }
    if (!bridge->api.db_load_directory(bridge->database, database_path)) {
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "Lensfun 没有从离线数据库目录加载任何 XML：%s", database_path);
        goto failure;
    }
    if (!lfb_prepare_profiles(bridge, error_buffer, error_buffer_capacity)) {
        goto failure;
    }

    char availability[256];
    (void)snprintf(availability, sizeof(availability),
                   "Lensfun 0.3.4 已加载（%zu 个 lens profile）。",
                   bridge->profile_count);
    bridge->availability = lfb_strdup(availability);
    if (bridge->availability == NULL) {
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "无法保存 Lensfun 状态信息。");
        goto failure;
    }
    return bridge;

failure:
    lfb_destroy(bridge);
    return NULL;
}

void lfb_destroy(LFBBridge *bridge)
{
    if (bridge == NULL) {
        return;
    }
    lfb_free_profiles(bridge);
    free(bridge->availability);
    if (bridge->database != NULL && bridge->api.db_destroy != NULL) {
        bridge->api.db_destroy(bridge->database);
    }
    if (bridge->api.library != NULL) {
        (void)dlclose(bridge->api.library);
    }
    if (bridge->mutex_initialized) {
        pthread_mutex_destroy(&bridge->database_lock);
    }
    free(bridge);
}

const char *lfb_availability(const LFBBridge *bridge)
{
    return bridge == NULL ? NULL : bridge->availability;
}

size_t lfb_profile_count(const LFBBridge *bridge)
{
    return bridge == NULL ? 0 : bridge->profile_count;
}

int lfb_profile_at(const LFBBridge *bridge, size_t index, LFBProfileInfo *out_profile)
{
    if (bridge == NULL || out_profile == NULL || index >= bridge->profile_count) {
        return 0;
    }
    *out_profile = bridge->profiles[index].public_info;
    return 1;
}

LFBStatus lfb_compute_geometry_map(LFBBridge *bridge,
                                   const char *profile_identifier,
                                   const char *camera_make,
                                   const char *camera_model,
                                   const char *lens_maker,
                                   const char *lens_model,
                                   double focal_length_mm,
                                   double crop_factor,
                                   int width,
                                   int height,
                                   float **out_map,
                                   size_t *out_float_count,
                                   LFBMapInfo *out_info,
                                   char *error_buffer,
                                   size_t error_buffer_capacity)
{
    if (error_buffer != NULL && error_buffer_capacity > 0) {
        error_buffer[0] = '\0';
    }
    if (out_map != NULL) {
        *out_map = NULL;
    }
    if (out_float_count != NULL) {
        *out_float_count = 0;
    }
    if (out_info != NULL) {
        memset(out_info, 0, sizeof(*out_info));
    }
    if (bridge == NULL || out_map == NULL || out_float_count == NULL || out_info == NULL ||
        width <= 0 || height <= 0 ||
        !lfb_finite_range(focal_length_mm, 1.0, 2000.0) ||
        !lfb_finite_range(crop_factor, 0.0, 10.0)) {
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "Lensfun 校正参数无效。");
        return LFB_STATUS_INVALID_ARGUMENT;
    }
    if ((size_t)width > SIZE_MAX / (size_t)height ||
        (size_t)width * (size_t)height > SIZE_MAX / (2 * sizeof(float))) {
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "Lensfun 映射尺寸超出可用内存范围。");
        return LFB_STATUS_INVALID_ARGUMENT;
    }

    const int has_camera_make = camera_make != NULL && camera_make[0] != '\0';
    const int has_camera_model = camera_model != NULL && camera_model[0] != '\0';
    const int has_camera_information = has_camera_make || has_camera_model;
    const int has_lens_model = lens_model != NULL && lens_model[0] != '\0';
    const int has_manual_profile = profile_identifier != NULL && profile_identifier[0] != '\0';

    const lfLens *selected_lens = NULL;
    LFBProfileRecord *selected_profile = NULL;
    const lfCamera *selected_camera = NULL;
    double selected_crop_factor = crop_factor;
    LFBStatus status = LFB_STATUS_OK;

    if (pthread_mutex_lock(&bridge->database_lock) != 0) {
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "无法锁定 Lensfun 数据库。");
        return LFB_STATUS_UNAVAILABLE;
    }

    if (has_manual_profile) {
        selected_profile = lfb_find_profile(bridge, profile_identifier);
        if (selected_profile == NULL) {
            status = LFB_STATUS_NO_MATCH;
            lfb_set_error(error_buffer, error_buffer_capacity,
                          "所选镜头 profile 不属于当前 Lensfun 数据库。");
            goto finish_database_lookup;
        }
        selected_lens = selected_profile->lens;
        if (has_camera_information) {
            if (!has_camera_make || !has_camera_model) {
                status = LFB_STATUS_MISSING_METADATA;
                lfb_set_error(error_buffer, error_buffer_capacity,
                              "手动镜头 profile 需要完整的相机品牌和型号才能验证卡口兼容性。");
                goto finish_database_lookup;
            }
            selected_camera = lfb_find_unique_camera(bridge, camera_make,
                                                      camera_model, &status);
            if (selected_camera == NULL) {
                if (status == LFB_STATUS_NO_MATCH) {
                    lfb_set_error(error_buffer, error_buffer_capacity,
                                  "无法识别相机 profile，不能验证手动镜头的卡口兼容性。");
                } else if (status == LFB_STATUS_AMBIGUOUS) {
                    lfb_set_error(error_buffer, error_buffer_capacity,
                                  "相机信息匹配到多个 profile，不能验证手动镜头兼容性。");
                }
                goto finish_database_lookup;
            }
            if (!lfb_lens_is_compatible(bridge, selected_camera, selected_profile)) {
                status = LFB_STATUS_INCOMPATIBLE;
                lfb_set_error(error_buffer, error_buffer_capacity,
                              "所选镜头 profile 与相机卡口或裁切系数不兼容。");
                goto finish_database_lookup;
            }
        } else if (selected_crop_factor == 0) {
            status = LFB_STATUS_MISSING_METADATA;
            lfb_set_error(error_buffer, error_buffer_capacity,
                          "缺少相机裁切系数；手动 profile 需要设置裁切系数覆盖值。");
            goto finish_database_lookup;
        }
    } else {
        if (!has_camera_make || !has_camera_model || !has_lens_model) {
            status = LFB_STATUS_MISSING_METADATA;
            lfb_set_error(error_buffer, error_buffer_capacity,
                          "自动匹配需要完整的相机品牌、型号和镜头型号信息。");
            goto finish_database_lookup;
        }
        selected_camera = lfb_find_unique_camera(bridge, camera_make,
                                                  camera_model, &status);
        if (selected_camera == NULL) {
            if (status == LFB_STATUS_NO_MATCH) {
                lfb_set_error(error_buffer, error_buffer_capacity,
                              "Lensfun 数据库没有匹配的相机 profile。");
            } else if (status == LFB_STATUS_AMBIGUOUS) {
                lfb_set_error(error_buffer, error_buffer_capacity,
                              "相机信息对应多个 profile，已跳过自动镜头匹配。");
            }
            goto finish_database_lookup;
        }
        const lfLens **matches = bridge->api.db_find_lenses_hd(
            bridge->database, selected_camera, lens_maker, lens_model,
            LF_SEARCH_SORT_AND_UNIQUIFY);
        size_t match_count = lfb_count_lens_array(matches);
        if (match_count == 0) {
            status = LFB_STATUS_NO_MATCH;
            lfb_set_error(error_buffer, error_buffer_capacity,
                          "Lensfun 没有找到兼容的镜头 profile。");
        } else if (match_count > 1) {
            status = LFB_STATUS_AMBIGUOUS;
            lfb_set_error(error_buffer, error_buffer_capacity,
                          "镜头信息匹配到多个 profile，已跳过自动校正。");
        } else {
            selected_lens = matches[0];
            selected_profile = NULL;
            for (size_t index = 0; index < bridge->profile_count; ++index) {
                if (bridge->profiles[index].lens == selected_lens) {
                    selected_profile = &bridge->profiles[index];
                    break;
                }
            }
            if (selected_profile == NULL) {
                status = LFB_STATUS_NO_MATCH;
                lfb_set_error(error_buffer, error_buffer_capacity,
                              "镜头 profile 无法在 Lensfun 镜头列表中确认。");
            }
        }
        if (matches != NULL) {
            bridge->api.free_memory((void *)matches);
        }
        if (status != LFB_STATUS_OK) {
            goto finish_database_lookup;
        }
    }

    if (selected_crop_factor == 0) {
        if (selected_camera == NULL ||
            !lfb_finite_range(selected_camera->CropFactor, 0.01, 10.0)) {
            status = LFB_STATUS_MISSING_METADATA;
            lfb_set_error(error_buffer, error_buffer_capacity,
                          "没有可靠的相机裁切系数；请提供裁切系数覆盖值。");
            goto finish_database_lookup;
        }
        selected_crop_factor = selected_camera->CropFactor;
    }
    if (!lfb_finite_range(selected_crop_factor, 0.01, 10.0)) {
        status = LFB_STATUS_INVALID_ARGUMENT;
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "裁切系数必须大于 0 且不超过 10。");
        goto finish_database_lookup;
    }

finish_database_lookup:
    pthread_mutex_unlock(&bridge->database_lock);
    if (status != LFB_STATUS_OK) {
        return status;
    }

    lfModifier *modifier = bridge->api.modifier_new(selected_lens,
                                                     (float)selected_crop_factor,
                                                     width, height);
    if (modifier == NULL) {
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "Lensfun 无法为当前照片创建校正 modifier。");
        return LFB_STATUS_OUT_OF_MEMORY;
    }
    const int required_flags = LF_MODIFY_DISTORTION | LF_MODIFY_SCALE;
    const int enabled_flags = bridge->api.modifier_initialize(
        modifier, selected_lens, LF_PF_F32, (float)focal_length_mm,
        0.0f, 0.0f, 0.0f, LF_UNKNOWN, required_flags, 0);
    if ((enabled_flags & LF_MODIFY_DISTORTION) == 0) {
        bridge->api.modifier_destroy(modifier);
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "所选 profile 没有适用于当前焦距和裁切系数的畸变标定。");
        return LFB_STATUS_UNSUPPORTED;
    }

    size_t pixel_count = (size_t)width * (size_t)height;
    size_t float_count = pixel_count * 2;
    size_t allocation_bytes = float_count * sizeof(float);
    float *map = NULL;
    if (posix_memalign((void **)&map, 16, allocation_bytes) != 0 || map == NULL) {
        bridge->api.modifier_destroy(modifier);
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "无法分配 Lensfun 几何映射缓冲区。");
        return LFB_STATUS_OUT_OF_MEMORY;
    }
    if (!bridge->api.modifier_apply_geometry_distortion(modifier, 0.0f, 0.0f,
                                                         width, height, map)) {
        free(map);
        bridge->api.modifier_destroy(modifier);
        lfb_set_error(error_buffer, error_buffer_capacity,
                      "Lensfun 无法为当前 profile 生成畸变映射。");
        return LFB_STATUS_MAP_FAILED;
    }
    float scale = bridge->api.modifier_get_auto_scale(modifier, 0);
    bridge->api.modifier_destroy(modifier);

    *out_map = map;
    *out_float_count = float_count;
    out_info->profile_identifier = selected_profile->public_info.identifier;
    out_info->profile_name = selected_profile->public_info.name;
    out_info->profile_maker = selected_profile->public_info.maker;
    out_info->crop_factor = selected_crop_factor;
    out_info->scale = isfinite(scale) ? scale : 0.0;
    return LFB_STATUS_OK;
}

void lfb_release_map(float *map)
{
    free(map);
}

const char *lfb_status_message(LFBStatus status)
{
    switch (status) {
        case LFB_STATUS_OK: return "Lensfun 校正成功。";
        case LFB_STATUS_UNAVAILABLE: return "Lensfun 当前不可用。";
        case LFB_STATUS_NO_MATCH: return "没有找到匹配的 Lensfun profile。";
        case LFB_STATUS_AMBIGUOUS: return "Lensfun profile 匹配结果不唯一。";
        case LFB_STATUS_INCOMPATIBLE: return "Lensfun 镜头 profile 与相机不兼容。";
        case LFB_STATUS_MISSING_METADATA: return "缺少镜头校正所需的照片信息。";
        case LFB_STATUS_UNSUPPORTED: return "镜头 profile 没有当前参数对应的畸变标定。";
        case LFB_STATUS_MAP_FAILED: return "Lensfun 无法生成几何映射。";
        case LFB_STATUS_INVALID_ARGUMENT: return "Lensfun 校正参数无效。";
        case LFB_STATUS_OUT_OF_MEMORY: return "Lensfun 映射内存不足。";
    }
    return "未知的 Lensfun 状态。";
}
