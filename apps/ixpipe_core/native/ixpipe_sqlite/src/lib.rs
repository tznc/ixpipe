//! SQLite for ixpipe's SQLite tools, through rusqlite with SQLite bundled.
//! Every call opens the database, does its work and closes it; errors come
//! back as `{:error, message}`.

use rusqlite::types::{Value, ValueRef};
use rusqlite::{Connection, OpenFlags};
use rustler::{Binary, Encoder, Env, NifResult, OwnedBinary, Term, TermType};

mod atoms {
    rustler::atoms! { ok, error, nil }
}

fn reply<'a, T: Encoder>(env: Env<'a>, result: Result<T, String>) -> Term<'a> {
    match result {
        Ok(value) => (atoms::ok(), value).encode(env),
        Err(message) => (atoms::error(), message).encode(env),
    }
}

fn reply_ok<'a>(env: Env<'a>, result: Result<(), String>) -> Term<'a> {
    match result {
        Ok(()) => atoms::ok().encode(env),
        Err(message) => (atoms::error(), message).encode(env),
    }
}

/// Runs `sql` (one or more statements) against the database at `path`,
/// creating it if needed.
#[rustler::nif(schedule = "DirtyIo")]
fn execute<'a>(env: Env<'a>, path: String, sql: String) -> Term<'a> {
    let result = Connection::open(&path)
        .and_then(|conn| conn.execute_batch(&sql))
        .map_err(|e| e.to_string());
    reply_ok(env, result)
}

/// Runs a read-only `sql` query: `{:ok, {columns, rows}}`. NULL is nil,
/// INTEGER an integer, REAL a float, TEXT a string and BLOB a binary.
#[rustler::nif(schedule = "DirtyIo")]
fn query<'a>(env: Env<'a>, path: String, sql: String) -> Term<'a> {
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let result = Connection::open_with_flags(&path, flags)
        .and_then(|conn| {
            let mut statement = conn.prepare(&sql)?;
            let columns: Vec<String> = statement
                .column_names()
                .iter()
                .map(|c| c.to_string())
                .collect();
            let n = columns.len();
            let mut rows = statement.query([])?;
            let mut out: Vec<Vec<Term<'a>>> = Vec::new();
            while let Some(row) = rows.next()? {
                let mut values = Vec::with_capacity(n);
                for i in 0..n {
                    values.push(encode(env, row.get_ref(i)?));
                }
                out.push(values);
            }
            Ok((columns, out))
        })
        .map_err(|e| e.to_string());
    reply(env, result)
}

/// In one transaction, runs each of `before`, then `insert` once per row of
/// parameters. On any error nothing is kept.
#[rustler::nif(schedule = "DirtyIo")]
fn write<'a>(
    env: Env<'a>,
    path: String,
    before: Vec<String>,
    insert: String,
    rows: Vec<Vec<Term<'a>>>,
) -> NifResult<Term<'a>> {
    let rows: Vec<Vec<Value>> = rows
        .into_iter()
        .map(|row| row.into_iter().map(decode).collect::<NifResult<Vec<_>>>())
        .collect::<NifResult<_>>()?;

    let result = (|| -> rusqlite::Result<()> {
        let mut conn = Connection::open(&path)?;
        let tx = conn.transaction()?;
        for sql in &before {
            tx.execute_batch(sql)?;
        }
        {
            let mut statement = tx.prepare(&insert)?;
            for row in &rows {
                statement.execute(rusqlite::params_from_iter(row.iter()))?;
            }
        }
        tx.commit()
    })()
    .map_err(|e| e.to_string());
    Ok(reply_ok(env, result))
}

fn encode<'a>(env: Env<'a>, value: ValueRef) -> Term<'a> {
    match value {
        ValueRef::Null => atoms::nil().encode(env),
        ValueRef::Integer(i) => i.encode(env),
        ValueRef::Real(f) => f.encode(env),
        ValueRef::Text(t) => String::from_utf8_lossy(t).encode(env),
        ValueRef::Blob(b) => {
            let mut bin = OwnedBinary::new(b.len()).expect("allocate a binary");
            bin.as_mut_slice().copy_from_slice(b);
            bin.release(env).encode(env)
        }
    }
}

fn decode(term: Term) -> NifResult<Value> {
    Ok(match term.get_type() {
        TermType::Atom if term == atoms::nil().to_term(term.get_env()) => Value::Null,
        TermType::Integer => Value::Integer(term.decode()?),
        TermType::Float => Value::Real(term.decode()?),
        TermType::Binary => {
            let bin: Binary = term.decode()?;
            match std::str::from_utf8(bin.as_slice()) {
                Ok(text) => Value::Text(text.to_string()),
                Err(_) => Value::Blob(bin.as_slice().to_vec()),
            }
        }
        _ => return Err(rustler::Error::BadArg),
    })
}

rustler::init!("Elixir.IxpipeCore.Sqlite");
