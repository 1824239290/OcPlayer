# Shared Bangumi account policy


## Retained account state

The production BangumiAPIClient now retains the same Core handle for HTTP and
`bangumiAccount.*` policy. Credential/OAuth/refresh generations, single-flight
refresh ownership, expiration/session reuse and auth-service revision barriers
are owned by Core. Swift executes credential storage, sessions, effect tasks,
watchdog waits, notifications and profile/UI writes. Injected native transports
and Core-disabled runs retain the independent implementation.

OAuth state is consumed before the token request, preventing concurrent callback
replay and preserving a later authorization when an older request completes.
Logout also retires pending state. Shared refresh tasks are keyed by their Core
claim, so retired cleanup cannot remove a newer task. Real native and Core HTTP
race fixtures cover these behaviors. Collection/account effect scheduling and
complete sync acceptance remain open.
