//! Freezes the pure-Python stdlib modules the sandbox's allowed modules
//! need, and no others, into the library.

use std::path::Path;

/// Modules and packages (directories) from RustPython's Lib.
const MODULES: &[&str] = &[
    "_collections_abc", "_markupbase", "_pydecimal", "_strptime", "_weakrefset", "abc", "base64",
    "bisect", "calendar", "codecs", "collections", "contextvars", "copy", "copyreg", "csv",
    "datetime", "decimal", "difflib", "encodings", "enum", "fractions", "functools",
    "genericpath", "hashlib", "heapq", "html", "io", "json", "keyword", "linecache", "locale",
    "numbers", "operator", "posixpath", "pprint", "random", "re", "reprlib", "stat", "statistics",
    "string", "struct", "textwrap", "types", "typing", "warnings", "weakref",
];

fn main() {
    let lib = Path::new(rustpython_pylib::LIB_PATH);
    let out = Path::new(&std::env::var("OUT_DIR").unwrap()).join("pylib");
    let _ = std::fs::remove_dir_all(&out);
    for module in MODULES {
        let dir = lib.join(module);
        if dir.is_dir() {
            copy_dir(&dir, &out.join(module));
        } else {
            std::fs::create_dir_all(&out).unwrap();
            std::fs::copy(lib.join(format!("{module}.py")), out.join(format!("{module}.py")))
                .unwrap_or_else(|e| panic!("{module}: {e}"));
        }
    }
    let frozen = Path::new(&std::env::var("OUT_DIR").unwrap()).join("frozen.rs");
    std::fs::write(frozen, format!("rustpython_vm::py_freeze!(dir = {:?})", out.display().to_string()))
        .unwrap();
    println!("cargo:rerun-if-changed=build.rs");
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap() {
        let path = entry.unwrap().path();
        let name = path.file_name().unwrap();
        if path.is_dir() {
            if name != "tests" && name != "__pycache__" {
                copy_dir(&path, &to.join(name));
            }
        } else if path.extension().is_some_and(|e| e == "py") {
            std::fs::copy(&path, to.join(name)).unwrap();
        }
    }
}
