use std::{env, fs, path::PathBuf};

fn main() {
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let target = env::var("TARGET").unwrap();
    let windows = target.contains("windows");
    let mut config = String::from("#define STDC_HEADERS 1\n");
    for name in [
        "STDINT_H",
        "STDIO_H",
        "STDLIB_H",
        "STRING_H",
        "INTTYPES_H",
        "TIME_H",
        "ERRNO_H",
        "FCNTL_H",
        "SYS_STAT_H",
        "SYS_TYPES_H",
        "SOCKADDR_STORAGE",
        "LINGER",
    ] {
        config.push_str(&format!("#define HAVE_{name} 1\n"));
    }
    if !windows {
        for name in [
            "ARPA_INET_H",
            "NETDB_H",
            "NETINET_IN_H",
            "NETINET_TCP_H",
            "POLL_H",
            "STRINGS_H",
            "SYS_IOCTL_H",
            "SYS_POLL_H",
            "SYS_SOCKET_H",
            "SYS_UIO_H",
            "SYS_TIME_H",
            "UNISTD_H",
            "SYS_ERRNO_H",
        ] {
            config.push_str(&format!("#define HAVE_{name} 1\n"));
        }
        if target.contains("apple") {
            config.push_str("#define HAVE_SOCKADDR_LEN 1\n");
        }
    }
    fs::write(out.join("config.h"), config).unwrap();
    // Preserve the complete upstream source. Apply our bounded enumeration and
    // malformed-entry checks only to the build copy; see vendor/README.md.
    let original = fs::read_to_string("vendor/libsmb2/lib/libsmb2.c").unwrap();
    let patched = original.replace("uint32_t offset = 0;\n\n        do {", "uint32_t offset = 0;\n        if (vec->len > 8 * 1024 * 1024 || dir->index > 8 * 1024 * 1024 - vec->len) return -1;\n        dir->index += vec->len;\n\n        do {")
        .replace("ent = calloc(1, sizeof(struct smb2_dirent_internal));", "if (++dir->entries_seen > 50000) return -1;\n                ent = calloc(1, sizeof(struct smb2_dirent_internal));")
        .replace("smb2_decode_fileidfulldirectoryinformation(smb2, &fs,\n                                                           &tmp_vec);", "if (smb2_decode_fileidfulldirectoryinformation(smb2, &fs, &tmp_vec) < 0) return -1;\n                if (!fs.name || (fs.next_entry_offset && (fs.next_entry_offset < 80 || fs.next_entry_offset >= tmp_vec.len))) { free((void *)fs.name); return -1; }");
    assert_ne!(original, patched);
    fs::write(out.join("libsmb2.c"), patched).unwrap();
    let private = fs::read_to_string("vendor/libsmb2/include/libsmb2-private.h").unwrap();
    let private = private.replace(
        "struct smb2dir {",
        "struct smb2dir {\n        uint32_t entries_seen;",
    );
    fs::write(out.join("libsmb2-private.h"), private).unwrap();
    let query = fs::read_to_string("vendor/libsmb2/lib/smb2-cmd-query-directory.c").unwrap();
    let query = query
        .replace(
            "uint32_t name_len;",
            "uint32_t name_len = 0;\n        if (vec->len < 80) return -1;",
        )
        .replace(
            "if (name_len > 80 + name_len ||",
            "if ((name_len & 1) || name_len > 80 + name_len ||",
        );
    fs::write(out.join("smb2-cmd-query-directory.c"), query).unwrap();
    let compat = fs::read_to_string("vendor/libsmb2/lib/compat.h")
        .unwrap()
        .replace(
            "int gethostname(char* name, size_t len);",
            "#ifndef __MINGW32__\nint gethostname(char* name, size_t len);\n#endif",
        );
    fs::write(out.join("compat.h"), compat).unwrap();
    let mut build = cc::Build::new();
    build
        .include(&out)
        .include("vendor/libsmb2/lib")
        .include("vendor/libsmb2/include")
        .include("vendor/libsmb2/include/smb2")
        .define("HAVE_CONFIG_H", None)
        .define("_FILE_OFFSET_BITS", "64")
        .warnings(false)
        .flag_if_supported("-fvisibility=hidden")
        .file("src/shim.c")
        .file(out.join("libsmb2.c"))
        .file(out.join("smb2-cmd-query-directory.c"));
    if windows {
        for name in [
            "WIN32",
            "_WINDOWS",
            "WIN32_LEAN_AND_MEAN",
            "_CRT_SECURE_NO_WARNINGS",
            "NEED_GETLOGIN_R",
            "NEED_GETPID",
            "NEED_RANDOM",
            "NEED_SRANDOM",
        ] {
            build.define(name, None);
        }
        if target.ends_with("gnu") {
            build.define("_ASPRINTF_H_", None);
        }
        build.define("_U_", "");
        println!("cargo:rustc-link-lib=ws2_32");
    } else {
        build.define("_U_", "__attribute__((unused))");
    }
    for entry in fs::read_dir("vendor/libsmb2/lib").unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_some_and(|e| e == "c")
            && !matches!(
                path.file_name().unwrap().to_str().unwrap(),
                "libsmb2.c" | "smb2-cmd-query-directory.c" | "krb5-wrapper.c"
            )
        {
            let copied = out.join(path.file_name().unwrap());
            if path.file_name().unwrap() == "socket.c" {
                let source = fs::read_to_string(&path).unwrap();
                let patched=source.replace("smb2->spl = be32toh(smb2->spl);", "smb2->spl = be32toh(smb2->spl);\n                if (smb2->spl < 64 || smb2->spl > 8 * 1024 * 1024) { smb2_set_error(smb2, \"SMB packet exceeds client limits\"); return -1; }");
                assert_ne!(source, patched);
                fs::write(&copied, patched).unwrap();
            } else {
                fs::copy(path, &copied).unwrap();
            }
            build.file(copied);
        }
    }
    build.compile("ocp_smb2");
    println!("cargo:rerun-if-changed=vendor");
    println!("cargo:rerun-if-changed=src/shim.c");
}
