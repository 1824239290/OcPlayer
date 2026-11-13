#ifndef OCPLAYER_CORE_H
#define OCPLAYER_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OcpCore OcpCore;

OcpCore *ocp_core_create(const char *config_json);
void ocp_core_destroy(OcpCore *core);
uint32_t ocp_core_abi_version(void);
char *ocp_call(OcpCore *core, const char *method, const char *arguments_json);
char *ocp_snapshot(OcpCore *core, const char *snapshot_kind);
int32_t ocp_poll_event(OcpCore *core, char **event_json);
void ocp_attach_surface(OcpCore *core, uint64_t native_handle, uint32_t width,
                        uint32_t height, double scale, uint32_t surface_kind);
void ocp_resize_surface(OcpCore *core, uint32_t width, uint32_t height, double scale);
void ocp_detach_surface(OcpCore *core);
void ocp_render_tick(OcpCore *core, double time_seconds);
void ocp_string_free(char *value);
char *ocp_last_error_message(void);

#ifdef __cplusplus
}
#endif

#endif
