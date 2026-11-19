# libsmb2 source

Pinned upstream tag: `libsmb2-6.2`, https://github.com/sahlberg/libsmb2

Original codeload archive SHA-256:
`8e1f9efc6b2e0f6546f0fe121ac0ddf4fc2f0908ae5a6bd1f185be7c9e0bcbb3`.
The complete original source and LGPL-2.1 license are retained in `libsmb2/`.
The tag's internal CMake/version constants differ from its release tag.

`build.rs` compiles a private static library with `cc`, NTLMSSP, SMB2/3,
signing and SMB3 encryption. Kerberos and system credential discovery are
disabled. No download, system SMB mount or installed libsmb2 is needed.

Our build copy adds a per-directory limit of 50,000 entries / 8 MiB wire data
before allocation, an 8 MiB incoming packet limit, and checks directory decode
failures, odd/truncated UTF-16 names and invalid next-entry offsets. MinGW uses
its existing asprintf/gethostname declarations; the build selects Windows
socket types consistently. The original source is unchanged. Cancellation
destroys the owned async context; no synchronous network wait or detached C
worker is used.

The Rust owner serializes context creation/destruction because upstream's
process-wide `active_contexts` list has no lock. Reading, polling and network
waiting remain independent across contexts; the lifecycle lock never spans IO.
