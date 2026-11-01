#ifndef PHOTO_ATELIER_C_LENSFUN_BRIDGE_H
#define PHOTO_ATELIER_C_LENSFUN_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LFBBridge LFBBridge;

typedef enum LFBStatus {
    LFB_STATUS_OK = 0,
    LFB_STATUS_UNAVAILABLE,
    LFB_STATUS_NO_MATCH,
    LFB_STATUS_AMBIGUOUS,
    LFB_STATUS_INCOMPATIBLE,
    LFB_STATUS_MISSING_METADATA,
    LFB_STATUS_UNSUPPORTED,
    LFB_STATUS_MAP_FAILED,
    LFB_STATUS_INVALID_ARGUMENT,
    LFB_STATUS_OUT_OF_MEMORY
} LFBStatus;

typedef struct LFBProfileInfo {
    /* Borrowed pointers remain valid until the LFBBridge is destroyed. */
    const char *identifier;
    const char *name;
    const char *maker;
    double crop_factor;
} LFBProfileInfo;

typedef struct LFBMapInfo {
    /* Borrowed pointers remain valid until the LFBBridge is destroyed. */
    const char *profile_identifier;
    const char *profile_name;
    const char *profile_maker;
    double crop_factor;
    double scale;
} LFBMapInfo;

/*
 * Opens the vendored Lensfun runtime and database. The roots may be NULL;
 * development builds resolve .dependencies/lensfun below project_root, while
 * bundled builds resolve Lensfun below the supplied Frameworks and Resources
 * roots. Errors are returned as text and do not abort the process.
 */
LFBBridge *lfb_create(const char *project_root,
                      const char *bundle_frameworks_root,
                      const char *bundle_resources_root,
                      char *error_buffer,
                      size_t error_buffer_capacity);

void lfb_destroy(LFBBridge *bridge);
const char *lfb_availability(const LFBBridge *bridge);
size_t lfb_profile_count(const LFBBridge *bridge);
int lfb_profile_at(const LFBBridge *bridge, size_t index, LFBProfileInfo *out_profile);

/*
 * Builds a full-resolution inverse geometry map in Lensfun pixel coordinates.
 * profile_identifier selects an explicit lens when non-NULL; otherwise camera
 * and lens metadata must resolve to exactly one compatible profile. A zero
 * crop_factor uses the matched camera profile's crop factor. With an explicit
 * lens profile and no camera metadata, callers must supply a crop factor; the
 * lens calibration crop factor is never guessed as the camera crop.
 *
 * On success, out_map owns a 16-byte-aligned, width*height*2 float allocation;
 * release it with lfb_release_map. The modifier is private to this invocation.
 */
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
                                   size_t error_buffer_capacity);

void lfb_release_map(float *map);
const char *lfb_status_message(LFBStatus status);

#ifdef __cplusplus
}
#endif

#endif /* PHOTO_ATELIER_C_LENSFUN_BRIDGE_H */
