//! Sandboxed Python for ixpipe's Python tool: RustPython embedded as a NIF.
//!
//! The sandbox is layered:
//!
//! - RustPython is built without `host_env`, so the interpreter has no `os`,
//!   `posix`, `socket`, `_ctypes`, `mmap` or file I/O modules to reach. A
//!   stub `os` (no files, processes or environment) lets pure-Python stdlib
//!   modules such as `random` import.
//! - User code can import only an allow-list of pure-Python modules, and
//!   `open` raises.
//! - Each run gets a fresh interpreter on its own thread, with a large stack
//!   so deep recursion is a `RecursionError`, not a crash. A watchdog thread
//!   interrupts it past its CPU time, wall time or memory budget, or when
//!   cancelled; the interrupt is re-sent until the script gives up, so
//!   catching it does not help.
//!
//! The NIF that waits for a run is on a dirty scheduler.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rustler::{Atom, Encoder, Env, NifResult, ResourceArc, Term, TermType};
use rustpython_vm::builtins::{PyBaseExceptionRef, PyDict, PyFloat, PyInt, PyList, PyStr, PyTuple};
use rustpython_vm::function::FuncArgs;
use rustpython_vm::scope::Scope;
use rustpython_vm::signal::{UserSignal, UserSignalSender, user_signal_channel};
use rustpython_vm::{AsObject, Interpreter, PyObjectRef, PyResult, Settings, VirtualMachine};

mod atoms {
    rustler::atoms! {
        ok, error, nil, date, datetime, time,
        exception, timeout, cancelled, memory, no_output, bad_output, crashed
    }
}

/// The pure-Python stdlib modules the allowed ones need (build.rs).
const FROZEN: &rustpython_vm::frozen::FrozenLib = include!(concat!(env!("OUT_DIR"), "/frozen.rs"));

/// The name tracebacks give the user's script.
const SCRIPT: &str = "script.py";

/// Modules user code may import. Everything here is pure computation.
const ALLOWED: &[&str] = &[
    "array", "base64", "binascii", "bisect", "calendar", "cmath", "collections", "copy", "csv",
    "datetime", "decimal", "difflib", "enum", "fractions", "functools", "hashlib",
    "heapq", "html", "itertools", "json", "math", "numbers", "operator", "pprint", "random", "re",
    "statistics", "string", "struct", "textwrap", "time", "typing", "unicodedata",
];

/// The sandbox's `os`: what pure-Python modules look up at import, and no
/// way to files, processes or the environment.
const OS_STUB: &str = r#"
name = "posix"
sep = "/"
altsep = None
extsep = "."
pathsep = ":"
linesep = "\n"
curdir = "."
pardir = ".."
defpath = ""
devnull = "/dev/null"
environ = {}
supports_bytes_environ = False

def getenv(key, default=None):
    return default

def fspath(path):
    if isinstance(path, (str, bytes)):
        return path
    fs = getattr(type(path), "__fspath__", None)
    if fs is None:
        raise TypeError("expected str, bytes or os.PathLike object")
    return fs(path)

def fsencode(name):
    return fspath(name).encode() if isinstance(fspath(name), str) else fspath(name)

def fsdecode(name):
    return fspath(name).decode() if isinstance(fspath(name), bytes) else fspath(name)

class PathLike:
    pass

_seed = [0]

def urandom(n):
    # Not cryptographic: seeds random and hash-based ids, nothing more.
    import hashlib, time
    out = b""
    while len(out) < n:
        _seed[0] += 1
        out += hashlib.sha256(f"{time.time_ns()}:{_seed[0]}:{id(out)}".encode()).digest()
    return out[:n]

def getpid():
    return 1

def register_at_fork(**kwargs):
    pass

def cpu_count():
    return 1

def _unavailable(*args, **kwargs):
    raise PermissionError("The sandboxed Python tool has no files, processes or environment.")

stat = lstat = listdir = scandir = remove = unlink = mkdir = makedirs = rmdir = rename = _unavailable
system = popen = execv = execve = fork = kill = chdir = getcwd = walk = _unavailable
"#;

/// Run before user code, with the real import: stdout capture and the stub `os`.
const PRELUDE: &str = r#"
import sys, _io
_os = type(sys)("os")
exec(_OS_STUB, _os.__dict__)
sys.modules["os"] = _os
import posixpath
_os.path = posixpath
sys.modules["os.path"] = posixpath
sys.stdout = sys.stderr = sys.__stdout__ = sys.__stderr__ = _io.StringIO()
sys.stdin = sys.__stdin__ = None
sys.setrecursionlimit(_RECURSION)
import builtins
for _name in ("input", "breakpoint", "help", "exit", "quit", "copyright", "credits", "license"):
    builtins.__dict__.pop(_name, None)
"#;

// ---------------------------------------------------------------------------
// Memory accounting: a counting allocator for this library's allocations
// (RustPython's), metered per run thread.

thread_local! {
    static METER: Cell<*const AtomicIsize> = const { Cell::new(std::ptr::null()) };
}

struct Counting;

fn meter(delta: isize) {
    let _ = METER.try_with(|m| {
        let ptr = m.get();
        if !ptr.is_null() {
            // SAFETY: the run thread sets the pointer to an Arc it keeps
            // alive until it clears it.
            unsafe { (*ptr).fetch_add(delta, Ordering::Relaxed) };
        }
    });
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let p = unsafe { System.alloc(layout) };
        if !p.is_null() {
            meter(layout.size() as isize);
        }
        p
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let p = unsafe { System.alloc_zeroed(layout) };
        if !p.is_null() {
            meter(layout.size() as isize);
        }
        p
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) };
        meter(-(layout.size() as isize));
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let p = unsafe { System.realloc(ptr, layout, new_size) };
        if !p.is_null() {
            meter(new_size as isize - layout.size() as isize);
        }
        p
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

// ---------------------------------------------------------------------------
// Jobs: a handle Elixir holds to cancel a run.

const RUNNING: u8 = 0;
const TIMEOUT: u8 = 1;
const CANCELLED: u8 = 2;
const MEMORY: u8 = 3;

pub struct Job {
    cancel: AtomicBool,
}

#[rustler::resource_impl]
impl rustler::Resource for Job {}

#[rustler::nif]
fn job() -> ResourceArc<Job> {
    ResourceArc::new(Job {
        cancel: AtomicBool::new(false),
    })
}

#[rustler::nif]
fn cancel(job: ResourceArc<Job>) -> Atom {
    job.cancel.store(true, Ordering::SeqCst);
    atoms::ok()
}

// ---------------------------------------------------------------------------
// Values crossing the boundary.

#[derive(Clone, Debug)]
enum Value {
    Nil,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
    Date(i64, i64, i64),
    DateTime(i64, i64, i64, i64, i64, i64, i64),
    Time(i64, i64, i64, i64),
}

fn decode_value(term: Term) -> NifResult<Value> {
    Ok(match term.get_type() {
        TermType::Atom => {
            if term == atoms::nil().to_term(term.get_env()) {
                Value::Nil
            } else {
                Value::Bool(term.decode()?)
            }
        }
        TermType::Integer => Value::Int(term.decode()?),
        TermType::Float => Value::Float(term.decode()?),
        TermType::Binary => Value::Str(term.decode()?),
        TermType::Tuple => {
            let items = rustler::types::tuple::get_tuple(term)?;
            let tag: Atom = items[0].decode()?;
            let n: Vec<i64> = items[1..].iter().map(|t| t.decode()).collect::<NifResult<_>>()?;
            if tag == atoms::date() && n.len() == 3 {
                Value::Date(n[0], n[1], n[2])
            } else if tag == atoms::datetime() && n.len() == 7 {
                Value::DateTime(n[0], n[1], n[2], n[3], n[4], n[5], n[6])
            } else if tag == atoms::time() && n.len() == 4 {
                Value::Time(n[0], n[1], n[2], n[3])
            } else {
                return Err(rustler::Error::BadArg);
            }
        }
        _ => return Err(rustler::Error::BadArg),
    })
}

impl Encoder for Value {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Value::Nil => atoms::nil().encode(env),
            Value::Bool(b) => b.encode(env),
            Value::Int(i) => i.encode(env),
            Value::Float(f) => f.encode(env),
            Value::Str(s) => s.encode(env),
            Value::Date(y, m, d) => (atoms::date(), *y, *m, *d).encode(env),
            Value::DateTime(y, mo, d, h, mi, s, us) => {
                (atoms::datetime(), (*y, *mo, *d), (*h, *mi, *s, *us)).encode(env)
            }
            Value::Time(h, m, s, us) => (atoms::time(), *h, *m, *s, *us).encode(env),
        }
    }
}

struct Input {
    name: String,
    columns: Vec<String>,
    rows: Vec<Vec<Value>>,
}

struct Output {
    columns: Vec<String>,
    rows: Vec<Vec<Value>>,
}

enum Failure {
    Exception {
        kind: u8,
        name: String,
        message: String,
        traceback: String,
    },
    NoOutput,
    BadOutput(String),
}

struct Outcome {
    result: Result<Output, Failure>,
    stdout: String,
}

// ---------------------------------------------------------------------------
// The NIF.

/// Runs `code` with `inputs` (`[{name, columns, rows}]`) under `limits`
/// (`{cpu_ms, wall_ms, memory_bytes, recursion}`). Replies
/// `{:ok, {columns, rows}, stdout}` or `{:error, kind, {name, message, traceback}, stdout}`.
#[rustler::nif(name = "run_nif", schedule = "DirtyCpu")]
fn run<'a>(
    env: Env<'a>,
    job: ResourceArc<Job>,
    code: String,
    inputs: Vec<(String, Vec<String>, Vec<Vec<Term<'a>>>)>,
    limits: (u64, u64, u64, u32),
) -> NifResult<Term<'a>> {
    let inputs = inputs
        .into_iter()
        .map(|(name, columns, rows)| {
            let rows = rows
                .into_iter()
                .map(|row| row.into_iter().map(decode_value).collect::<NifResult<Vec<_>>>())
                .collect::<NifResult<Vec<_>>>()?;
            Ok(Input { name, columns, rows })
        })
        .collect::<NifResult<Vec<_>>>()?;

    let (cpu_ms, wall_ms, memory, recursion) = limits;
    let used = Arc::new(AtomicIsize::new(0));
    let state = Arc::new(AtomicU8::new(RUNNING));
    let sender: Arc<Mutex<Option<UserSignalSender>>> = Arc::new(Mutex::new(None));
    let clock: Arc<Mutex<Option<libc::clockid_t>>> = Arc::new(Mutex::new(None));

    let worker = {
        let (used, state, sender, clock) = (used.clone(), state.clone(), sender.clone(), clock.clone());
        std::thread::Builder::new()
            .name("ixpipe-python".into())
            // Deep recursion must hit Python's limit long before the stack's.
            .stack_size(512 * 1024 * 1024)
            .spawn(move || {
                *clock.lock().unwrap() = thread_clock();
                METER.with(|m| m.set(Arc::as_ptr(&used)));
                let outcome = interpret(&code, &inputs, recursion, &sender, &state);
                METER.with(|m| m.set(std::ptr::null()));
                outcome
            })
            .expect("spawn the Python thread")
    };

    // The watchdog: CPU time, wall time, memory and cancellation.
    let started = Instant::now();
    let mut armed = false;
    while !worker.is_finished() {
        std::thread::sleep(Duration::from_millis(5));
        if state.load(Ordering::SeqCst) == RUNNING {
            let tripped = if job.cancel.load(Ordering::SeqCst) {
                CANCELLED
            } else if used.load(Ordering::Relaxed) > memory as isize {
                MEMORY
            } else if started.elapsed() > Duration::from_millis(wall_ms)
                || clock.lock().unwrap().is_some_and(|c| cpu_time(c) > Duration::from_millis(cpu_ms))
            {
                TIMEOUT
            } else {
                RUNNING
            };
            if tripped != RUNNING {
                let _ = state.compare_exchange(RUNNING, tripped, Ordering::SeqCst, Ordering::SeqCst);
            }
        }
        // Once tripped, interrupt the script at every instruction until it
        // stops: catching the interrupt only lands it in the next one.
        let reason = state.load(Ordering::SeqCst);
        if reason != RUNNING && !armed {
            if let Some(tx) = sender.lock().unwrap().as_ref() {
                let _ = tx.send(rearming(tx.clone(), reason));
                armed = true;
            }
        }
    }

    let outcome = match worker.join() {
        Ok(outcome) => outcome,
        Err(_) => {
            return Ok((atoms::error(), atoms::crashed(), ("Crash", "The interpreter crashed.", ""), "")
                .encode(env));
        }
    };

    // Whatever surfaced, a tripped limit is why the script stopped.
    let reason = state.load(Ordering::SeqCst);
    Ok(match outcome.result {
        Ok(output) if reason == RUNNING => {
            (atoms::ok(), (output.columns, output.rows), outcome.stdout).encode(env)
        }
        Ok(_) => (atoms::error(), reason_atom(reason), ("", "", ""), outcome.stdout).encode(env),
        Err(Failure::Exception { kind, name, message, traceback }) => {
            let kind = if reason != RUNNING { reason } else { kind };
            (atoms::error(), reason_atom(kind), (name, message, traceback), outcome.stdout)
                .encode(env)
        }
        Err(Failure::NoOutput) => {
            (atoms::error(), atoms::no_output(), ("", "", ""), outcome.stdout).encode(env)
        }
        Err(Failure::BadOutput(what)) => {
            (atoms::error(), atoms::bad_output(), ("", what, ""), outcome.stdout).encode(env)
        }
    })
}

fn reason_atom(reason: u8) -> Atom {
    match reason {
        TIMEOUT => atoms::timeout(),
        CANCELLED => atoms::cancelled(),
        MEMORY => atoms::memory(),
        _ => atoms::exception(),
    }
}

/// An interrupt that queues itself again as it fires, so the VM raises at
/// its next instruction too, and the one after: inside an `except` or
/// `finally` as well.
fn rearming(tx: UserSignalSender, reason: u8) -> UserSignal {
    Box::new(move |vm: &VirtualMachine| {
        let _ = tx.send(rearming(tx.clone(), reason));
        Err(interrupt(vm, reason))
    })
}

fn interrupt(vm: &VirtualMachine, reason: u8) -> PyBaseExceptionRef {
    let (kind, message) = match reason {
        MEMORY => (vm.ctx.exceptions.memory_error, "memory limit reached"),
        CANCELLED => (vm.ctx.exceptions.keyboard_interrupt, "run cancelled"),
        _ => (vm.ctx.exceptions.keyboard_interrupt, "time limit reached"),
    };
    vm.new_exception_msg(kind.to_owned(), message.into())
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn thread_clock() -> Option<libc::clockid_t> {
    let mut clock: libc::clockid_t = 0;
    // SAFETY: pthread_self is always valid for the calling thread.
    let rc = unsafe { libc::pthread_getcpuclockid(libc::pthread_self(), &mut clock) };
    (rc == 0).then_some(clock)
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn thread_clock() -> Option<libc::clockid_t> {
    None
}

fn cpu_time(clock: libc::clockid_t) -> Duration {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: `ts` is a valid out-pointer; a clock of a finished thread fails.
    if unsafe { libc::clock_gettime(clock, &mut ts) } != 0 {
        return Duration::ZERO;
    }
    Duration::new(ts.tv_sec as u64, ts.tv_nsec as u32)
}

// ---------------------------------------------------------------------------
// The interpreter.

fn interpret(
    code: &str,
    inputs: &[Input],
    recursion: u32,
    sender: &Mutex<Option<UserSignalSender>>,
    state: &AtomicU8,
) -> Outcome {
    let (tx, rx) = user_signal_channel();
    let mut settings = Settings::default();
    settings.install_signal_handlers = false;
    settings.import_site = false;
    settings.isolated = true;
    settings.ignore_environment = true;
    settings.user_site_directory = false;
    settings.write_bytecode = false;
    settings.safe_path = true;

    let mut builder = Interpreter::builder(settings);
    let defs = rustpython_stdlib::stdlib_module_defs(&builder.ctx);
    builder = builder
        .add_native_modules(&defs)
        .add_frozen_modules(FROZEN)
        .init_hook(move |vm| vm.set_user_signal_channel(rx));
    let interpreter = builder.build();
    *sender.lock().unwrap() = Some(tx);

    let outcome = interpreter.enter(|vm| {
        let result = setup(vm, recursion).and_then(|_| {
            let scope = user_scope(vm, inputs)?;
            match vm.run_string(scope.clone(), code, SCRIPT) {
                Ok(_) => Ok(Ok(scope)),
                Err(exc) => Ok(Err(exc)),
            }
        });

        let result = match result {
            Ok(Ok(scope)) => read_output(vm, &scope),
            Ok(Err(exc)) | Err(exc) => Err(exception(vm, &exc, state)),
        };
        Outcome {
            result,
            stdout: stdout(vm),
        }
    });

    *sender.lock().unwrap() = None;
    drop(interpreter);
    outcome
}

/// The stub `os`, stdout capture, the import allow-list and no `open`.
fn setup(vm: &VirtualMachine, recursion: u32) -> PyResult<()> {
    let scope = vm.new_scope_with_builtins();
    scope.globals.set_item("__name__", vm.ctx.new_str("_ixpipe_sandbox").into(), vm)?;
    scope.globals.set_item("_OS_STUB", vm.ctx.new_str(OS_STUB).into(), vm)?;
    scope.globals.set_item("_RECURSION", vm.ctx.new_int(recursion).into(), vm)?;
    vm.run_string(scope, PRELUDE, "<sandbox>")?;

    let builtins = vm.builtins.clone();
    let real_import = builtins.get_attr("__import__", vm)?;
    let guarded = vm.new_function("__import__", move |args: FuncArgs, vm: &VirtualMachine| -> PyResult {
        check_import(&args, vm)?;
        real_import.call(args, vm)
    });
    builtins.set_attr("__import__", guarded, vm)?;

    let no_files = vm.new_function("open", |_args: FuncArgs, vm: &VirtualMachine| -> PyResult {
        Err(vm.new_exception_msg(
            vm.ctx.exceptions.permission_error.to_owned(),
            "The sandboxed Python tool can't open files. Read your data from inputs and set output instead."
                .into(),
        ))
    });
    builtins.set_attr("open", no_files, vm)?;
    Ok(())
}

/// User code (globals named `__main__`, or no globals) imports only allowed
/// modules; the stdlib's own imports pass.
fn check_import(args: &FuncArgs, vm: &VirtualMachine) -> PyResult<()> {
    let name: String = match args.args.first() {
        Some(name) => name.str(vm)?.to_string(),
        None => return Ok(()),
    };
    let globals = args.args.get(1).cloned().or_else(|| args.kwargs.get("globals").cloned());
    let level = match args.args.get(4).or_else(|| args.kwargs.get("level")) {
        Some(level) => level.try_to_value::<i64>(vm).unwrap_or(0),
        None => 0,
    };
    let caller = match globals {
        Some(g) if !vm.is_none(&g) => match g.downcast_ref::<PyDict>() {
            Some(dict) => match dict.get_item_opt("__name__", vm)? {
                Some(n) => n.str(vm)?.to_string(),
                None => "__main__".to_owned(),
            },
            None => "__main__".to_owned(),
        },
        _ => "__main__".to_owned(),
    };
    if caller != "__main__" {
        return Ok(());
    }
    let top = name.split('.').next().unwrap_or("");
    if level == 0 && ALLOWED.contains(&top) {
        return Ok(());
    }
    let shown = if level > 0 { format!("{}{}", ".".repeat(level as usize), name) } else { top.to_owned() };
    Err(vm.new_exception_msg(
        vm.ctx.exceptions.import_error.to_owned(),
        format!(
            "{shown} isn't allowed in the sandboxed Python tool. Allowed modules: {}. Use the Script tool for anything else.",
            ALLOWED.join(", ")
        )
        .into(),
    ))
}

fn user_scope(vm: &VirtualMachine, inputs: &[Input]) -> PyResult<Scope> {
    let scope = vm.new_scope_with_builtins();
    scope.globals.set_item("__name__", vm.ctx.new_str("__main__").into(), vm)?;
    let datetime = vm.import("datetime", 0)?;
    let tables = vm.ctx.new_dict();
    for input in inputs {
        let keys: Vec<PyObjectRef> = input.columns.iter().map(|c| vm.ctx.new_str(c.as_str()).into()).collect();
        let mut rows = Vec::with_capacity(input.rows.len());
        for row in &input.rows {
            let dict = vm.ctx.new_dict();
            for (key, value) in keys.iter().zip(row) {
                dict.set_item(&**key, to_python(vm, &datetime, value)?, vm)?;
            }
            rows.push(dict.into());
        }
        tables.set_item(input.name.as_str(), vm.ctx.new_list(rows).into(), vm)?;
    }
    scope.globals.set_item("inputs", tables.into(), vm)?;
    Ok(scope)
}

fn to_python(vm: &VirtualMachine, datetime: &PyObjectRef, value: &Value) -> PyResult {
    Ok(match value {
        Value::Nil => vm.ctx.none(),
        Value::Bool(b) => vm.ctx.new_bool(*b).into(),
        Value::Int(i) => vm.ctx.new_int(*i).into(),
        Value::Float(f) => vm.ctx.new_float(*f).into(),
        Value::Str(s) => vm.ctx.new_str(s.as_str()).into(),
        Value::Date(y, m, d) => datetime.get_attr("date", vm)?.call((*y, *m, *d), vm)?,
        Value::DateTime(y, mo, d, h, mi, s, us) => {
            let parts: Vec<PyObjectRef> =
                [y, mo, d, h, mi, s, us].iter().map(|n| vm.ctx.new_int(**n).into()).collect();
            datetime.get_attr("datetime", vm)?.call(FuncArgs::from(parts), vm)?
        }
        Value::Time(h, m, s, us) => datetime.get_attr("time", vm)?.call((*h, *m, *s, *us), vm)?,
    })
}

/// `output`: a list of dicts (columns in first-seen order) or a dict of
/// column lists.
fn read_output(vm: &VirtualMachine, scope: &Scope) -> Result<Output, Failure> {
    let output = match scope.globals.get_item_opt("output", vm) {
        Ok(Some(output)) => output,
        Ok(None) => return Err(Failure::NoOutput),
        Err(exc) => return Err(exception(vm, &exc, &AtomicU8::new(RUNNING))),
    };
    convert_output(vm, &output).map_err(|e| match e {
        Ok(failure) => failure,
        Err(exc) => exception(vm, &exc, &AtomicU8::new(RUNNING)),
    })
}

type Converted<T> = Result<T, Result<Failure, PyBaseExceptionRef>>;

fn convert_output(vm: &VirtualMachine, output: &PyObjectRef) -> Converted<Output> {
    let datetime = vm.import("datetime", 0).map_err(Err)?;
    if let Some(list) = output.downcast_ref::<PyList>() {
        let items: Vec<PyObjectRef> = list.borrow_vec().to_vec();
        let mut columns: Vec<String> = Vec::new();
        let mut dicts = Vec::with_capacity(items.len());
        for item in &items {
            let Some(dict) = item.downcast_ref::<PyDict>() else {
                return Err(Ok(Failure::BadOutput(format!(
                    "output is a list of {}, not of dicts",
                    item.class().name()
                ))));
            };
            let mut pairs = Vec::new();
            for (key, value) in dict {
                let key = key.str(vm).map_err(Err)?.to_string();
                if !columns.contains(&key) {
                    columns.push(key.clone());
                }
                pairs.push((key, value));
            }
            dicts.push(pairs);
        }
        let mut rows = Vec::with_capacity(dicts.len());
        for pairs in dicts {
            let mut row = vec![Value::Nil; columns.len()];
            for (key, value) in pairs {
                let i = columns.iter().position(|c| *c == key).unwrap();
                row[i] = from_python(vm, &datetime, &value).map_err(Err)?;
            }
            rows.push(row);
        }
        return Ok(Output { columns, rows });
    }
    if let Some(dict) = output.downcast_ref::<PyDict>() {
        let mut columns = Vec::new();
        let mut values: Vec<Vec<Value>> = Vec::new();
        for (key, column) in dict {
            columns.push(key.str(vm).map_err(Err)?.to_string());
            let items: Vec<PyObjectRef> = vm.extract_elements_with(&column, Ok).map_err(Err)?;
            let column = items
                .iter()
                .map(|v| from_python(vm, &datetime, v))
                .collect::<PyResult<Vec<_>>>()
                .map_err(Err)?;
            values.push(column);
        }
        let n = values.first().map_or(0, Vec::len);
        if values.iter().any(|v| v.len() != n) {
            return Err(Ok(Failure::BadOutput("output's columns have different lengths".into())));
        }
        let rows = (0..n).map(|i| values.iter().map(|c| c[i].clone()).collect()).collect();
        return Ok(Output { columns, rows });
    }
    Err(Ok(Failure::BadOutput(format!("output is a {}", output.class().name()))))
}

fn from_python(vm: &VirtualMachine, datetime: &PyObjectRef, value: &PyObjectRef) -> PyResult<Value> {
    if vm.is_none(value) {
        return Ok(Value::Nil);
    }
    if value.is(&vm.ctx.true_value) {
        return Ok(Value::Bool(true));
    }
    if value.is(&vm.ctx.false_value) {
        return Ok(Value::Bool(false));
    }
    if let Some(int) = value.downcast_ref::<PyInt>() {
        return Ok(match int.try_to_primitive::<i64>(vm) {
            Ok(i) => Value::Int(i),
            Err(_) => Value::Str(int.as_bigint().to_string()),
        });
    }
    if let Some(float) = value.downcast_ref::<PyFloat>() {
        return Ok(Value::Float(float.to_f64()));
    }
    if let Some(s) = value.downcast_ref::<PyStr>() {
        return Ok(Value::Str(s.to_string_lossy().into_owned()));
    }
    let int = |name: &'static str| -> PyResult<i64> { value.get_attr(name, vm)?.try_to_value::<i64>(vm) };
    // datetime is a date: test it first.
    if value.is_instance(&*datetime.get_attr("datetime", vm)?, vm)? {
        return Ok(Value::DateTime(
            int("year")?, int("month")?, int("day")?,
            int("hour")?, int("minute")?, int("second")?, int("microsecond")?,
        ));
    }
    if value.is_instance(&*datetime.get_attr("date", vm)?, vm)? {
        return Ok(Value::Date(int("year")?, int("month")?, int("day")?));
    }
    if value.is_instance(&*datetime.get_attr("time", vm)?, vm)? {
        return Ok(Value::Time(int("hour")?, int("minute")?, int("second")?, int("microsecond")?));
    }
    if value.downcast_ref::<PyTuple>().is_some() || value.downcast_ref::<PyList>().is_some() {
        return Ok(Value::Str(value.repr(vm)?.to_string_lossy().into_owned()));
    }
    Ok(Value::Str(value.str(vm)?.to_string_lossy().into_owned()))
}

fn exception(vm: &VirtualMachine, exc: &PyBaseExceptionRef, state: &AtomicU8) -> Failure {
    let mut traceback = String::new();
    let _ = vm.write_exception(&mut traceback, exc);
    let name = exc.class().name().to_string();
    let message = exc
        .as_object()
        .str(vm)
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    Failure::Exception {
        kind: state.load(Ordering::SeqCst),
        name,
        message,
        traceback,
    }
}

fn stdout(vm: &VirtualMachine) -> String {
    vm.sys_module
        .get_attr("stdout", vm)
        .and_then(|out| vm.call_method(&out, "getvalue", ()))
        .ok()
        .and_then(|v| v.downcast_ref::<PyStr>().map(|s| s.to_string_lossy().into_owned()))
        .unwrap_or_default()
}

rustler::init!("Elixir.IxpipeCore.Python");
