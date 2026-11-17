# Retained MoviePilot request validation — 2026-11-14

The selected MoviePilot actor's complete raw/named retry and auth replay sequence
now runs in retained `moviepilotFlow.*` policy. Core owns method idempotence,
retry budgets, backoff/jitter bounds, latest-token reuse, shared refresh, one auth
replay per attempt and failure termination. The actor executes yielded effects
and retains original bytes/errors. Account begin/logout retires all flows;
accepted configuration commits retire older revisions while transparent refresh
preserves flows at the current revision. Typed original-byte login/current-user
decoding also preserves large integer IDs and all existing native user fields.

The final unified run passes Rust 151, C ABI 140, exported Apple SDK 19 and seven
native packages totaling 1221. MoviePilotKit passes 134 without skips. Full macOS
AppTests execute 1008: 989 pass, 19 platform skips, zero failures. Core-disabled
MoviePilot regression executes 134: 104 pass, 30 explicit library-only skips,
zero failures. A hash-verified independent 66-file source/schema copy passes all
151 locked/offline Rust tests. Source/native input hashes remain unchanged.
`summary.json`, input manifests and `verify-provenance.py` retain exact counts,
the independent source path and binary runtime-section hashes.

Four added Rust cases and seven public C ABI cases verify method/override policy,
raw/named retry owners, one replay per attempt, backoff/jitter bounds, terminal
refresh/replay failures, receipt validation, exact u64 revisions, cancellation,
configuration/account retirement, concurrent identifiers and the directory bound.
Five added native real-HTTP cases verify large integer IDs plus email/avatar and
false flags, failed refresh preserving the expired token without restarting the
raw read, post-refresh read retry budget, named transport-only retry and logout
during pending backoff without another HTTP dispatch. Existing real network/SSE,
authentication/fuse/race, byte-preserving and creation non-replay regressions pass.

`full-verification/` preserves complete raw gate output, Core-disabled regression,
signature checks and bundled playback/EOF logs. Fourteen file-backed runtime
Mach-O sections match the built dylib; full file hashes differ after signing.
Deep signature verification passes. Both bundled H.264/AAC self-tests finish
with zero render/audio failures and no feature/library environment override.
Natural EOF reaches `core=ended` at the observed 5.1 seconds for the 5.133333-second
clip. These debug checks do not certify all media formats, subtitles/HDR, remote
recovery or Apple release slices. Products remain in `/tmp/ocp-moviepilot-flow-macos`,
whose Xcode DerivedData reuses the previous verified tree.

Preliminary failures are preserved unchanged. The first library build omitted
`Some` in a Rust `if let`, binding an Option where a u64 was needed; correcting
that match makes the library build pass. The first ABI/native runs consequently
record an unavailable-library dependency failure. The corrected ABI fixture then
had a Python parameter named `method` colliding with the request argument;
renaming that parameter makes all seven cases pass. The first added native tests
also omitted `try` around the throwing library-path argument; correcting those
calls makes all 134 native cases pass. Later bounds logs and the final unified
run verify the final jitter policy and complete user field mapping. No failed
run was omitted or counted as successful verification.

See [the request contract](../../moviepilot-flow-contract.md) and
[remaining project acceptance](../../macos-parity.md). Detailed Bangumi
subject/progress operation chaining, complete account/profile effects, broad
playback/transport/settings acceptance, Apple release delivery and Windows
adapter completion remain active. Windows runtime testing remains deferred;
the complete project goal remains active.
