# TMDB network response verification

This cohort fixes exact network integer decoding and native JSONObject response
fidelity. The complete OcPlayer-Core goal remains in progress.

The unified run passes 100 Rust tests, 91 direct C ABI tests, 19 exported Apple
binding tests and 1178 tests across seven native packages. macOS AppTests pass
989 tests with 19 platform skips and no failures. Core-disabled MetadataKit
passes 301 tests with 12 explicit shared-fixture skips and no failures.

Two new Rust tests, five C ABI tests, two SDK tests and three native tests cover
the changed behavior. Native tests compare 42 complete models across 14 wire
scenarios with the independent JSONObject decoder. Initial focused passing logs
remain distinct from final verification records.

A hash-verified 55-file independent source/schema copy passes all 100 locked,
offline Rust tests. The Debug app reuses Xcode DerivedData, embeds the new Core
and passes deep signature verification. Its ten-second control selftest plays
a twenty-second H.264/AAC clip, exercises pause/play, seeks to fourteen/four
seconds, resize and rates 2.0/1.0, with zero rendering/audio failures.

`summary.json` contains counts and library hashes; source manifests record the
tested Rust and native files. Full raw logs remain in `full-verification/`.
Windows runtime testing is deferred. Enricher/batch, repository/account/playback
orchestration, platform transport fidelity and release delivery remain open.
