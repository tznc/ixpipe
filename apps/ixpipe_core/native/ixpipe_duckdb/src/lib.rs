//! DuckDB for ixpipe (a spike): runs SQL in an in-memory database and
//! returns the result as an Arrow IPC stream, which Explorer loads without
//! converting rows to Elixir terms.

use duckdb::arrow::ipc::writer::StreamWriter;
use duckdb::Connection;
use rustler::{Encoder, Env, OwnedBinary, Term};

mod atoms {
    rustler::atoms! { ok, error }
}

fn run(sql: &str, settings: &[(String, String)]) -> Result<Vec<u8>, String> {
    let conn = Connection::open_in_memory().map_err(|e| e.to_string())?;
    for (key, value) in settings {
        conn.execute_batch(&format!("SET {key} = '{}'", value.replace('\'', "''")))
            .map_err(|e| e.to_string())?;
    }
    let mut statement = conn.prepare(sql).map_err(|e| e.to_string())?;
    let batches = statement.query_arrow([]).map_err(|e| e.to_string())?;
    let schema = batches.get_schema();
    let mut writer = StreamWriter::try_new(Vec::new(), &schema).map_err(|e| e.to_string())?;
    for batch in batches {
        writer.write(&batch).map_err(|e| e.to_string())?;
    }
    writer.finish().map_err(|e| e.to_string())?;
    writer.into_inner().map_err(|e| e.to_string())
}

/// Runs `sql` with `settings` (`SET key = 'value'`): `{:ok, arrow_ipc_stream}`
/// or `{:error, message}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn query<'a>(env: Env<'a>, sql: String, settings: Vec<(String, String)>) -> Term<'a> {
    match run(&sql, &settings) {
        Ok(bytes) => {
            let mut bin = OwnedBinary::new(bytes.len()).expect("allocate a binary");
            bin.as_mut_slice().copy_from_slice(&bytes);
            (atoms::ok(), bin.release(env)).encode(env)
        }
        Err(message) => (atoms::error(), message).encode(env),
    }
}

rustler::init!("Elixir.IxpipeCore.Duck");
