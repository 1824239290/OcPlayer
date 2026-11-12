use ocp_core::Core;

fn main() {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("ping") => {
            let core = Core::new("{}").expect("create core");
            println!("{}", core.call("ping", "{}").expect("ping"));
        }
        Some("snapshot") => {
            let kind = args.next().unwrap_or_else(|| "core".to_string());
            let core = Core::new("{}").expect("create core");
            println!("{}", core.snapshot(&kind).expect("snapshot"));
        }
        _ => {
            eprintln!("usage: ocp-cli <ping|snapshot [core|playback]>");
            std::process::exit(2);
        }
    }
}
