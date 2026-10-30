//! DuckDB, ixpipe's engine. Each run opens one in-memory database (a
//! resource); every call works on its own connection to it, so Runic steps
//! on different branches query it concurrently. Values come back as Elixir
//! terms; dates, times and wide integers are tagged for `IxpipeCore.Duck`.

use std::sync::Mutex;

use duckdb::types::{TimeUnit, Value};
use duckdb::{appender_params_from_iter, Connection};
use rustler::{Encoder, Env, NifResult, ResourceArc, Term, TermType};

mod atoms {
    rustler::atoms! { ok, error, nil, date, time, timestamp, interval, int }
}

pub struct Db {
    conn: Mutex<Connection>,
}

#[rustler::resource_impl]
impl rustler::Resource for Db {}

fn connect(db: &Db) -> Result<Connection, String> {
    let conn = db
        .conn
        .lock()
        .map_err(|_| "the database is poisoned".to_string())?;
    conn.try_clone().map_err(|e| e.to_string())
}

/// Opens an in-memory database with `settings` (`SET key = 'value'`).
#[rustler::nif(name = "open_nif", schedule = "DirtyIo")]
fn open(settings: Vec<(String, String)>) -> Result<ResourceArc<Db>, String> {
    let conn = Connection::open_in_memory().map_err(|e| e.to_string())?;
    for (key, value) in settings {
        conn.execute_batch(&format!("SET {key} = '{}'", value.replace('\'', "''")))
            .map_err(|e| e.to_string())?;
    }
    Ok(ResourceArc::new(Db {
        conn: Mutex::new(conn),
    }))
}

/// Runs one or more statements.
#[rustler::nif(name = "execute_nif", schedule = "DirtyCpu")]
fn execute(db: ResourceArc<Db>, sql: String) -> Result<(), String> {
    connect(&db)?.execute_batch(&sql).map_err(|e| e.to_string())
}

/// Runs a query: `{columns, rows}`, each row a list in column order.
#[rustler::nif(name = "query_nif", schedule = "DirtyCpu")]
fn query<'a>(
    env: Env<'a>,
    db: ResourceArc<Db>,
    sql: String,
) -> Result<(Vec<String>, Vec<Vec<Term<'a>>>), String> {
    let conn = connect(&db)?;
    let mut statement = conn.prepare(&sql).map_err(|e| e.to_string())?;
    let mut rows = statement.query([]).map_err(|e| e.to_string())?;
    let columns: Vec<String> = rows.as_ref().map(|s| s.column_names()).unwrap_or_default();
    let n = columns.len();
    let mut out = Vec::new();
    while let Some(row) = rows.next().map_err(|e| e.to_string())? {
        let mut values = Vec::with_capacity(n);
        for i in 0..n {
            // duckdb-rs panics reading a column of DuckDB's NULL type
            // (`SELECT NULL`); every value in it is NULL.
            let value: Value =
                std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| row.get(i)))
                    .unwrap_or(Ok(Value::Null))
                    .map_err(|e| e.to_string())?;
            values.push(encode(env, value));
        }
        out.push(values);
    }
    Ok((columns, out))
}

/// Appends `rows` (lists in column order) to `table`.
#[rustler::nif(name = "append_nif", schedule = "DirtyIo")]
fn append<'a>(
    db: ResourceArc<Db>,
    table: String,
    rows: Vec<Vec<Term<'a>>>,
) -> NifResult<Result<(), String>> {
    let rows: Vec<Vec<Value>> = rows
        .into_iter()
        .map(|row| row.into_iter().map(decode).collect::<NifResult<Vec<_>>>())
        .collect::<NifResult<_>>()?;

    Ok((|| -> Result<(), String> {
        let conn = connect(&db)?;
        let mut appender = conn.appender(&table).map_err(|e| e.to_string())?;
        for row in rows {
            appender
                .append_row(appender_params_from_iter(row))
                .map_err(|e| e.to_string())?;
        }
        appender.flush().map_err(|e| e.to_string())
    })())
}

fn micros(unit: TimeUnit, v: i64) -> i64 {
    match unit {
        TimeUnit::Second => v * 1_000_000,
        TimeUnit::Millisecond => v * 1_000,
        TimeUnit::Microsecond => v,
        TimeUnit::Nanosecond => v / 1_000,
    }
}

fn wide<'a>(env: Env<'a>, digits: String) -> Term<'a> {
    (atoms::int(), digits).encode(env)
}

fn encode<'a>(env: Env<'a>, value: Value) -> Term<'a> {
    match value {
        Value::Null => atoms::nil().encode(env),
        Value::Boolean(b) => b.encode(env),
        Value::TinyInt(i) => (i as i64).encode(env),
        Value::SmallInt(i) => (i as i64).encode(env),
        Value::Int(i) => (i as i64).encode(env),
        Value::BigInt(i) => i.encode(env),
        Value::UTinyInt(i) => (i as u64).encode(env),
        Value::USmallInt(i) => (i as u64).encode(env),
        Value::UInt(i) => (i as u64).encode(env),
        Value::UBigInt(i) => i.encode(env),
        Value::HugeInt(i) => match i64::try_from(i) {
            Ok(small) => small.encode(env),
            Err(_) => wide(env, i.to_string()),
        },
        Value::UHugeInt(i) => match u64::try_from(i) {
            Ok(small) => small.encode(env),
            Err(_) => wide(env, i.to_string()),
        },
        Value::Float(f) => float(env, f as f64),
        Value::Double(f) => float(env, f),
        Value::Decimal(d) => float(env, d.to_string().parse().unwrap_or(f64::NAN)),
        Value::Timestamp(unit, v) => (atoms::timestamp(), micros(unit, v)).encode(env),
        Value::Text(s) | Value::Enum(s) => s.encode(env),
        Value::Blob(b) | Value::Geometry(b) => binary(env, &b),
        Value::Date32(days) => (atoms::date(), days as i64).encode(env),
        Value::Time64(unit, v) => (atoms::time(), micros(unit, v)).encode(env),
        Value::Interval {
            months,
            days,
            nanos,
        } => (atoms::interval(), months, days, nanos).encode(env),
        Value::List(items) | Value::Array(items) => items
            .into_iter()
            .map(|v| encode(env, v))
            .collect::<Vec<_>>()
            .encode(env),
        Value::Struct(fields) => {
            let mut map = Term::map_new(env);
            for (k, v) in fields.iter() {
                map = map
                    .map_put(k.encode(env), encode(env, v.clone()))
                    .expect("a map");
            }
            map
        }
        Value::Map(entries) => {
            let mut map = Term::map_new(env);
            for (k, v) in entries.iter() {
                map = map
                    .map_put(encode(env, k.clone()), encode(env, v.clone()))
                    .expect("a map");
            }
            map
        }
        Value::Union(inner) => encode(env, *inner),
        // A type newer than this NIF: its text, rather than nothing.
        other => format!("{other:?}").encode(env),
    }
}

// The BEAM has no NaN or infinities: they come back as nil.
fn float<'a>(env: Env<'a>, f: f64) -> Term<'a> {
    if f.is_finite() {
        f.encode(env)
    } else {
        atoms::nil().encode(env)
    }
}

fn binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut bin = rustler::OwnedBinary::new(bytes.len()).expect("allocate a binary");
    bin.as_mut_slice().copy_from_slice(bytes);
    bin.release(env).encode(env)
}

fn decode(term: Term) -> NifResult<Value> {
    Ok(match term.get_type() {
        TermType::Atom => match term.atom_to_string()?.as_str() {
            "nil" => Value::Null,
            "true" => Value::Boolean(true),
            "false" => Value::Boolean(false),
            _ => return Err(rustler::Error::BadArg),
        },
        TermType::Integer => match term.decode::<i64>() {
            Ok(i) => Value::BigInt(i),
            Err(_) => Value::HugeInt(term.decode::<i128>()?),
        },
        TermType::Float => Value::Double(term.decode()?),
        TermType::Binary => {
            let bin: rustler::Binary = term.decode()?;
            match std::str::from_utf8(bin.as_slice()) {
                Ok(text) => Value::Text(text.to_string()),
                Err(_) => Value::Blob(bin.as_slice().to_vec()),
            }
        }
        TermType::Tuple => {
            let (tag, v): (rustler::Atom, i64) = term.decode()?;
            if tag == atoms::date() {
                Value::Date32(v as i32)
            } else if tag == atoms::timestamp() {
                Value::Timestamp(TimeUnit::Microsecond, v)
            } else if tag == atoms::time() {
                Value::Time64(TimeUnit::Microsecond, v)
            } else {
                return Err(rustler::Error::BadArg);
            }
        }
        _ => return Err(rustler::Error::BadArg),
    })
}

rustler::init!("Elixir.IxpipeCore.Duck");
