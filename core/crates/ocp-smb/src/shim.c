#include "config.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#ifdef _WIN32
#include <winsock2.h>
#else
#include <poll.h>
#endif
#include "smb2/smb2.h"
#include "smb2/libsmb2.h"
#include "libsmb2-private.h"

// One operation and one owned context per reader. Callbacks remain valid until
// destroy_context has aborted all outstanding PDUs, including cancellation.
struct ocp_smb {
    struct smb2_context *context;
    struct smb2dir *dir;
    struct smb2fh *file;
    struct smb2_stat_64 stat;
    int done, status, operation;
};
struct ocp_smb_stat { uint64_t size, ino, mtime, mtime_ns, ctime, ctime_ns, btime, btime_ns; uint32_t type; };
static void callback(struct smb2_context *context, int status, void *data, void *opaque) {
    struct ocp_smb *s = opaque;
    s->done = 1; s->status = status;
    if (status >= 0 && s->operation == 1) s->dir = data;
    if (status >= 0 && s->operation == 2) s->file = data;
}
void ocp_smb_destroy(struct ocp_smb *s) {
    if (!s) return;
    smb2_destroy_context(s->context); free(s);
}
struct ocp_smb *ocp_smb_new(const char *user, const char *password, const char *domain, int sign, int seal) {
    struct ocp_smb *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->context = smb2_init_context();
    if (!s->context) { free(s); return NULL; }
    smb2_set_user(s->context, user); smb2_set_password(s->context, password); smb2_set_domain(s->context, domain);
    smb2_set_authentication(s->context, SMB2_SEC_NTLMSSP);
    smb2_set_version(s->context, seal ? SMB2_VERSION_ANY3 : SMB2_VERSION_ANY);
    smb2_set_security_mode(s->context, SMB2_NEGOTIATE_SIGNING_ENABLED | (sign ? SMB2_NEGOTIATE_SIGNING_REQUIRED : 0));
    smb2_set_sign(s->context, sign); smb2_set_seal(s->context, seal); smb2_set_timeout(s->context, 15);
    return s;
}
static void begin(struct ocp_smb *s, int op) { s->done = 0; s->status = 0; s->operation = op; }
int ocp_smb_connect(struct ocp_smb *s, const char *server, const char *share, const char *user) {
    begin(s, 0); return smb2_connect_share_async(s->context, server, share, user, callback, s);
}
int ocp_smb_list(struct ocp_smb *s, const char *path) { begin(s, 1); return smb2_opendir_async(s->context, path, callback, s); }
int ocp_smb_open(struct ocp_smb *s, const char *path) { begin(s, 2); return smb2_open_async(s->context, path, O_RDONLY, callback, s); }
int ocp_smb_stat(struct ocp_smb *s) { begin(s, 0); return smb2_fstat_async(s->context, s->file, &s->stat, callback, s); }
int ocp_smb_read(struct ocp_smb *s, uint8_t *buffer, uint32_t count, uint64_t offset) {
    begin(s, 0); return smb2_pread_async(s->context, s->file, buffer, count, offset, callback, s);
}
int ocp_smb_step(struct ocp_smb *s) {
    if (s->done) return 1;
    struct pollfd pfd;
    memset(&pfd, 0, sizeof(pfd)); pfd.fd = smb2_get_fd(s->context); pfd.events = smb2_which_events(s->context);
#ifdef _WIN32
    int polled = WSAPoll(&pfd, 1, 0);
#else
    int polled = poll(&pfd, 1, 0);
#endif
    if (polled < 0 || smb2_service(s->context, pfd.revents) < 0) return -1;
    if (!s->done && s->context->hdr.command == SMB2_SESSION_SETUP &&
        (s->context->hdr.status & 0xc0000000u) == 0xc0000000u &&
        s->context->hdr.status != SMB2_STATUS_MORE_PROCESSING_REQUIRED) return -1;
    return s->done ? 1 : 0;
}
int ocp_smb_status(struct ocp_smb *s) { return s->status; }
uint32_t ocp_smb_ntstatus(struct ocp_smb *s) {
    uint32_t status = (uint32_t)smb2_get_nterror(s->context);
    // A rejected session can fail packet/signature decoding before libsmb2
    // invokes its high-level callback. Report the already parsed failure code
    // only to classify a rejected operation, never to accept unauthenticated data.
    return status ? status : s->context->hdr.status;
}
static void copy_stat(struct ocp_smb_stat *out, const struct smb2_stat_64 *st) {
    out->size=st->smb2_size; out->ino=st->smb2_ino; out->type=st->smb2_type;
    out->mtime=st->smb2_mtime; out->mtime_ns=st->smb2_mtime_nsec;
    out->ctime=st->smb2_ctime; out->ctime_ns=st->smb2_ctime_nsec;
    out->btime=st->smb2_btime; out->btime_ns=st->smb2_btime_nsec;
}
void ocp_smb_get_stat(struct ocp_smb *s, struct ocp_smb_stat *out) { copy_stat(out, &s->stat); }
const char *ocp_smb_next(struct ocp_smb *s, struct ocp_smb_stat *out) {
    struct smb2dirent *entry = smb2_readdir(s->context, s->dir);
    if (!entry) return NULL;
    copy_stat(out, &entry->st); return entry->name;
}
