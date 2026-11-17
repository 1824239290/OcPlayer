# Shared Bangumi account/profile service flows

BangumiAuthService delegates its exchange, refreshProfile, logout and passive
invalidation operations to BangumiAuthLifecycle. When the API client selects Core,
RustBangumiAuthFlow uses the same handle and account to retain their complete
effect ordering and failure/rollback decisions. HTTP, original-byte profile
decoding, credential files, session/task execution, UserDefaults and UI changes
remain native adapters. The flow retains no credentials or profile payloads.

Exchange/profile operations validate both the operation revision and identity.
Transparent token refresh preserves identity; a newer account retires prior
fetches and commits. A failed or cancelled post-exchange profile clears only its
exchange generation and preserves the original error, even if credentials change
during rollback. Logout clears UI/profile/timestamp before credentials, then
clears DB rows only for a current operation and cleared credential. Passive 401
invalidation checks the original operation and credential generation before
starting a new operation; it leaves cached DB rows intact.
If observational invalidation reaches its bound, another duplicate request
returns safely; explicit account/profile operations can still retire old work.

Credential clearing now accepts an operation revision and checks it atomically
with an optional credential generation. Its native fallback holds the same
operation barrier around physical credential/session retirement. Account-local
DB clear also accepts a work revision and validates/retire/deletes under one lock,
so an old logout's delayed actor handoff cannot delete new-account rows.

BangumiAuthLifecycleTests use isolated credential/UserDefaults/SQL stores and
real HTTP in both modes. They verify every profile field and large integer IDs,
post-exchange failure/cancellation, replacement credentials during failure, late
fetch/commit, delayed logout deletion, physical conditional clearing, passive
invalidation, existing default-profile tolerance and ignored DB cleanup failure.
The Core repository's docs/bangumi-auth-flow-contract.md and validation ledger
retain the ABI and complete macOS evidence. Broader live-account, playback,
transport/settings and release acceptance remain part of the active goal.
