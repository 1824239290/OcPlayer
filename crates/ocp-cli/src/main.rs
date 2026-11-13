use ocp_core::Core;
use serde_json::Value;
use std::fs;
use std::io::{self, BufRead};

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
        Some("call") => {
            let Some(method) = args.next() else { usage() };
            let arguments = args.next().unwrap_or_else(|| "{}".to_string());
            let core = Core::new("{}").expect("create core");
            println!("{}", core.call(&method, &arguments).expect("call"));
        }
        Some("replay") => {
            let Some(path) = args.next() else { usage() };
            let input = if path == "-" {
                let mut input = String::new();
                for line in io::stdin().lock().lines() {
                    input.push_str(&line.expect("read stdin"));
                    input.push('\n');
                }
                input
            } else {
                fs::read_to_string(path).expect("read fixture")
            };
            let core = Core::new("{}").expect("create core");
            for line in input.lines().filter(|line| !line.trim().is_empty()) {
                let command: Value = serde_json::from_str(line).expect("parse fixture command");
                let method = command["method"].as_str().expect("fixture method");
                let arguments = command.get("arguments").cloned().unwrap_or(Value::Null);
                println!(
                    "{}",
                    core.call(method, &arguments.to_string()).expect("call")
                );
            }
            eprintln!("{}", core.snapshot("core").expect("snapshot"));
        }
        _ => {
            usage();
        }
    }
}

fn usage() -> ! {
    eprintln!("usage: ocp-cli <ping|snapshot [core|playback]|call METHOD [JSON]|replay FILE|->");
    std::process::exit(2)
}
