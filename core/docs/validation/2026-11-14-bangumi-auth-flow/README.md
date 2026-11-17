# Retained Bangumi account/profile validation — 2026-11-14

BangumiAuthService now delegates complete authorization exchange, profile refresh,
logout and passive session invalidation to retained bangumiAuthFlow effects on
its selected API account Core. Core owns their order, operation/identity guards,
post-exchange profile failure and cancellation rollback, conditional credential
cleanup, logout UI/credential/database order and current-generation adoption.
HTTP, original-byte typed/default profile decoding, credential files, session/task
execution, UserDefaults and native UI/database effects remain adapters. No profile
payload or credentials are retained in the authentication flow directory.

The final unified run passes Rust 161, C ABI 157 across 25 suites, exported Apple
SDK 19 and seven native packages totaling 1235. BangumiKit passes 122 without skips.
Full macOS AppTests execute 1008: 989 pass, 19 platform skips, zero failures.
Core-disabled Bangumi executes 122: 98 pass, 24 explicit library-only skips,
zero failures. An independent hash-verified 68-file source/schema copy passes all
161 locked/offline Rust tests. The 68 Core sources, 760 native build/test inputs
and 50 gate/binding inputs remain unchanged. summary.json and manifests retain
exact counts, the independent source path and binary runtime section hashes.

Six added Rust cases and eight public C ABI cases verify complete effect order,
profile rollback with the original generation, transparent refresh versus identity
or operation retirement, current cleared-generation adoption, optional operation
and credential constraints, signed/fractional/overflow rejection before mutation,
wrong acknowledgements, token exhaustion, cancellation, the 1024-observer bound
and explicit account operations remaining available. Identity-mismatched exchange
receipts now immediately retire their directory entry; they cannot validate or
resume later with another identity.

Eight added native cases run real local HTTP with isolated credentials,
UserDefaults and SQL stores in both selected-Core and independent native modes.
They compare every profile field, large signed IDs/joinedAt, avatar and false
permissions, exact request order and Bearer auth, cancellation/failure cleanup,
new credentials issued during failure while retaining the original error, late
HTTP/profile commit after logout/new login, delayed logout DB clearing, physical
conditional credential rejection, passive invalidation retaining cached DB rows,
profile default tolerance and ignored DB cleanup failure. A full observer directory
also returns safely from the nonthrowing invalidation API; a subsequent explicit
profile operation retires old observers and succeeds. Existing auth/refresh/fuse,
transport, progress, sync and all other package regressions pass.

full-verification/ retains complete raw gate, disabled regression, strict deep
signature verification and bundled controls/EOF output. Fourteen file-backed
runtime Mach-O sections match the built dylib; full file hashes differ after
signing. Both bundled H.264/AAC self-tests finish with zero render/audio failures
and no feature/library environment override. Natural EOF reaches core=ended at
5.1 seconds for the 5.133333-second clip. These Debug checks do not certify all
formats, subtitle/HDR, remote recovery or Apple release slices. Products remain
in /tmp/ocp-bangumi-auth-flow-macos; DerivedData reuses
/tmp/ocp-bangumi-progress-macos/DerivedData. verify-provenance.py checks frozen
inputs, the independent copy, exact counts and runtime section hashes.

All preliminary output remains unchanged. Initial Rust tests required Debug on
the new error type; deriving it makes them compile. The first new Swift fixtures
used a closure expression the compiler could not diagnose, directly mutated a
MainActor property from a Sendable closure and compared non-Equatable credentials;
explicit factory branches, an actor method and field comparisons correct these.
The next fixture forgot Bearer auth in its injected native session factory;
matching the native factory headers makes both modes pass. Review of an initially
passing complete run then reproduced an identity-mismatched exchange returning
retired while remaining active. The probe is retained, the directory now removes
that flow immediately, and Rust/ABI assertions verify it cannot validate again.
The native capacity boundary was subsequently covered and made nonfatal for
redundant passive invalidation. preliminary-unified/ and
preliminary-retirement-verified/ preserve both preceding complete runs and their
input manifests; the final unified run verifies the final source. No failing or
superseded run is presented as final verification.

See [the service-flow contract](../../bangumi-auth-flow-contract.md) and
[remaining project acceptance](../../macos-parity.md). The existing account/profile
service effect migration is complete for these four paths. Broad live-account,
playback/source/track/recovery, transport/settings/diagnostics acceptance, Apple
release delivery and Windows adapter completion remain active. Windows runtime
testing is deferred; the complete project goal remains active.
