#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#define OCP_EXPORT __declspec(dllexport)
static void wait_one_millisecond(void) { Sleep(1); }
#else
#include <unistd.h>
#define OCP_EXPORT
static void wait_one_millisecond(void) { usleep(1000); }
#endif

typedef struct OcpCore { atomic_int dead, active, cancelled, polled; } OcpCore;
static atomic_int created, destroyed, allocated, freed, active, use_after_destroy, cancelled, release_calls;
static char *owned(const char *text) { size_t size=strlen(text)+1; char *copy=malloc(size); memcpy(copy,text,size); atomic_fetch_add(&allocated,1); return copy; }
static int live(OcpCore *c) { if (!c || atomic_load(&c->dead)) { atomic_fetch_add(&use_after_destroy,1); return 0; } return 1; }
OCP_EXPORT OcpCore *ocp_core_create(const char *json) { (void)json; OcpCore *c=calloc(1,sizeof *c); atomic_fetch_add(&created,1); return c; }
OCP_EXPORT void ocp_core_destroy(OcpCore *c) {
 if (!live(c) || atomic_load(&c->active)) { atomic_fetch_add(&use_after_destroy,1); return; }
 atomic_store(&c->dead,1); atomic_fetch_add(&destroyed,1);
 /* Keep a tombstone so a bad managed binding is observable without crashing. */
}
OCP_EXPORT uint32_t ocp_core_abi_version(void) { return 1; }
OCP_EXPORT char *ocp_call(OcpCore *c, const char *method, const char *json) {
 if (!live(c)) return NULL;
 if (!strcmp(method,"request.prepare")) { atomic_store(&c->cancelled,0); return owned("{\"ok\":true,\"code\":0,\"retryable\":false,\"message\":\"\",\"data\":{}}"); }
 if (!strcmp(method,"request.cancel")) { atomic_store(&c->cancelled,1); atomic_fetch_add(&cancelled,1); return owned("{\"ok\":true,\"code\":0,\"retryable\":false,\"message\":\"\",\"data\":{}}"); }
 if (!strcmp(method,"block")) {
  atomic_fetch_add(&c->active,1); atomic_fetch_add(&active,1);
  for (int i=0; i<8000 && !atomic_load(&c->cancelled) && !atomic_load(&release_calls); ++i) wait_one_millisecond();
  atomic_fetch_sub(&c->active,1); atomic_fetch_sub(&active,1);
 }
 if (!strcmp(method,"null")) return NULL;
 if (!strcmp(method,"malformed")) return owned("{");
 const char *prefix="{\"ok\":true,\"code\":0,\"retryable\":false,\"message\":\"\",\"data\":";
 size_t length=strlen(prefix)+strlen(json)+2;char *out=malloc(length);
 snprintf(out,length,"%s%s}",prefix,json);atomic_fetch_add(&allocated,1);return out;
}
OCP_EXPORT char *ocp_snapshot(OcpCore *c,const char *kind) {
 (void)kind;if (!live(c))return NULL;
 return owned("{\"abi_version\":1,\"ready\":true,\"id\":9223372036854775807}");
}
OCP_EXPORT int32_t ocp_poll_event(OcpCore *c,char **value) {
 *value=NULL;if (!live(c))return -1;
 if (atomic_exchange(&c->polled,1))return 0;
 *value=owned("{\"sequence\":18446744073709551615,\"kind\":\"core.ready\",\"data\":{\"id\":9223372036854775807}}");return 1;
}
OCP_EXPORT void ocp_attach_surface(OcpCore *c,uint64_t h,uint32_t w,uint32_t z,double s,uint32_t k) { (void)h;(void)w;(void)z;(void)s;(void)k;live(c); }
OCP_EXPORT void ocp_resize_surface(OcpCore *c,uint32_t w,uint32_t h,double s) { (void)w;(void)h;(void)s;live(c); }
OCP_EXPORT void ocp_detach_surface(OcpCore *c) { live(c); }
OCP_EXPORT void ocp_render_tick(OcpCore *c,double s) { (void)s;live(c); }
OCP_EXPORT void ocp_string_free(char *value) { if (value) {atomic_fetch_add(&freed,1);free(value);} }
#ifndef OCP_FIXTURE_MISSING_EXPORT
OCP_EXPORT char *ocp_last_error_message(void) { return owned("fixture UTF-8 错误"); }
#endif
OCP_EXPORT int fixture_created(void) { return atomic_load(&created); }
OCP_EXPORT int fixture_destroyed(void) { return atomic_load(&destroyed); }
OCP_EXPORT int fixture_allocated(void) { return atomic_load(&allocated); }
OCP_EXPORT int fixture_freed(void) { return atomic_load(&freed); }
OCP_EXPORT int fixture_active(void) { return atomic_load(&active); }
OCP_EXPORT int fixture_uaf(void) { return atomic_load(&use_after_destroy); }
OCP_EXPORT int fixture_cancelled(void) { return atomic_load(&cancelled); }
OCP_EXPORT void fixture_release(void) { atomic_store(&release_calls,1); }
OCP_EXPORT void fixture_reset_release(void) { atomic_store(&release_calls,0); }
