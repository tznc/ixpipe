// libduckdb ships beside the NIF in priv/native, so the NIF looks for it
// in its own directory.
fn main() {
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    match os.as_str() {
        "macos" | "ios" => println!("cargo:rustc-link-arg=-Wl,-rpath,@loader_path"),
        "windows" => {}
        _ => println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN"),
    }
}
