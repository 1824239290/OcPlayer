#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
void *ocp_core_create(const char *config) { (void)config; return malloc(1); }
void ocp_core_destroy(void *core) { free(core); }
#ifndef FIXTURE_ABI_VERSION
#define FIXTURE_ABI_VERSION 1
#endif
uint32_t ocp_core_abi_version(void) { return FIXTURE_ABI_VERSION; }
char *ocp_call(void *core, const char *method, const char *args) {
 (void)core; const char *data = !strcmp(method,"echo") ? args : "{}";
 size_t size = strlen(data) + 90; char *out = malloc(size);
 snprintf(out,size,"{\"ok\":true,\"code\":0,\"retryable\":false,\"message\":\"\",\"data\":%s}",data);
 return out;
}
int32_t ocp_poll_event(void *core, char **event) { (void)core; *event = NULL; return 0; }
char *ocp_snapshot(void *core, const char *kind) { (void)core; (void)kind; return strdup("{}"); }
void ocp_attach_surface(void *c,uint64_t h,uint32_t w,uint32_t t,double s,uint32_t k) {(void)c;(void)h;(void)w;(void)t;(void)s;(void)k;}
void ocp_resize_surface(void *c,uint32_t w,uint32_t t,double s) {(void)c;(void)w;(void)t;(void)s;}
void ocp_detach_surface(void *c) {(void)c;}
void ocp_render_tick(void *c,double t) {(void)c;(void)t;}
void ocp_string_free(char *s) { free(s); }
#ifndef FIXTURE_MISSING_EXPORT
char *ocp_last_error_message(void) { return NULL; }
#endif
