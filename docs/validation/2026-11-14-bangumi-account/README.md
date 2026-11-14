# Bangumi retained account validation — 2026-11-14

Credential/OAuth/refresh generations, OAuth state consumption, single-flight
refresh claims and cleanup, expiration/session-reuse policy, timeout/stale error
classification and login/profile/logout revision barriers now run in retained
Core account state. The Apple actor uses its existing Core HTTP handle for
these decisions. Platform credential storage, native sessions, effect tasks,
watchdog waits, notifications and profile/UI writes remain native adapters.
Complete account/profile effect scheduling and collection sync remain open.

The final unified run passes Rust 138, actual C ABI 122, exported Apple SDK 19
and seven native packages totaling 1206. BangumiKit passes all 103 with no skips.
macOS AppTests execute 1008: 989 pass, 19 platform skips, zero failures. The
Core-disabled Bangumi regression executes 103: 89 pass, 14 Core-only skips,
zero failures. An independent hash-verified 63-file source/schema copy passes
all 138 locked/offline Rust tests. Counts, source manifests, final binary hashes
and fourteen matching runtime Mach-O sections are retained alongside this report.

Four new Rust state cases and five actual C ABI cases verify one owner across
64 concurrent refresh claims, conditional invalidation, stale commit rejection,
owner-specific cleanup, exact unsigned generations, invalid argument atomicity,
OAuth callback replay/latest exchange decisions, clock boundaries and profile
revision barriers. Four new native cases include production Core selection and
real HTTP comparisons between independent native and Core paths for logout
during refresh/token exchange, duplicate callbacks and later authorization.
The existing transport, refresh, persistence and complete application regression
also pass. The later authorization race exposed an existing Swift state cleanup
window; both paths now consume state before the token request and retire pending
state on logout.

`full-verification/` retains complete raw unified output. Build products remain
at `/tmp/ocp-bangumi-account-macos`; Xcode DerivedData is reused from the previous
verified checkout. The rebuilt app embeds the current Core and passes deep
signature verification. Its bundled ten-second H.264/AAC test exercises
pause/play, seeks, speed changes and resizing; the eight-second short-clip run
reaches native EOF and Core ended. Both finish with zero render/audio failures
and no library or feature environment override. These certify the stated clips
and controls, not all remaining formats, tracks, subtitles, HDR or remote recovery.

Preliminary output is preserved unchanged. `rust.log` records the external
volume's unsupported incremental lock; the corrected run uses `/tmp` for Cargo
output. `clock*.log` and `build-final.log` retain incomplete clock DTO edit
compile failures; `clock-verified.log` and `build-verified.log` pass. The initial
module insertion also produced a crate-documentation placement error during
formatting, corrected before the final checks. `native-races.log` records the
Swift compiler's diagnostic failure on a conditional optional closure expression;
`native-races-corrected.log` explicitly types the fixture values and passes all
103 tests. These were implementation/fixture compilation issues, not suppressed
runtime failures.

See [the account contract](../../bangumi-account-contract.md) and the remaining
[macOS parity scope](../../macos-parity.md). Windows execution remains deferred
by the user; the complete project goal remains active.
