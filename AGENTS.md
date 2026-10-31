# AGENTS.md

ixpipe: an open-source, Alteryx-style DAG workflow orchestrator. Native
desktop and mobile app in Elixir, rendered by GPUI through
[baguette](https://github.com/ziinc/baguette) (Tauri host, embedded BEAM).

## Layout (umbrella)

- `apps/ixpipe_core`: the engine, pure Elixir with no UI dependency.
  - `IxpipeCore.Spec` parses YAML workflows: `decode/1` (drafts), `validate/1` (runnable DAG), `to_yaml/1`.
  - `IxpipeCore.Edit` applies canvas edits (add, move, connect, remove) to drafts.
  - `IxpipeCore.run/2` compiles a spec to a [Runic](https://hex.pm/packages/runic) workflow and runs it in a fresh in-memory DuckDB v2 database (`IxpipeCore.Duck`): Runic orchestrates the DAG, and each node's output is a table there (`IxpipeCore.Table`, named for the node: `id`, or `id.output`). Runic steps run concurrently, each on its own connection; past `memory_limit` DuckDB spills to disk.
  - `IxpipeCore.execute/2` runs as Alteryx does and returns an `IxpipeCore.Run`: each node's status (ok, failed, skipped below a failure), the tables of every node that ran, and per-node `IxpipeCore.Message`s (info: rows and time; warnings; errors in "what happened. what to do." form via `IxpipeCore.Errors.humanize/1`, the raw DuckDB text as `detail`). `run/2` wraps it as `{:ok, tables}` or the first `{:node_failed, …}`. Tools record warnings with `Context.warn/2` and info with `Context.info/2` (safe across Runic's concurrent steps).
  - Tools (`IxpipeCore.Tools.*`) implement `IxpipeCore.Tool` over tables: `inputs/0`, `fields/0` (the settings schema the properties panel renders; `IxpipeCore.Config` parses and formats each type) and `run/3` (`inputs, config, %IxpipeCore.Context{}`), mostly SQL through `Context.sql/3`. Expressions in Filter and Formula are DuckDB SQL. Register new ones in `IxpipeCore.Tools` and in a ribbon group (`@ribbon`) in `MainView`; a test checks every tool is on exactly one tab.
  - Connectors: database servers through pure-Elixir drivers (`IxpipeCore.Server`: Postgres via postgrex, MySQL/MariaDB via myxql, SQL Server via tds; input and output tools each), SQLite through our NIF, and files through DuckDB (`IxpipeCore.Files`: CSV, Parquet and JSON, one file, a folder or a wildcard, unioned by name; Excel through xlsx_reader/elixlsx). File paths may be `s3://`, `gs://` or `az://` (`IxpipeCore.Cloud`): DuckDB's httpfs and azure extensions, downloaded on first use (not in libduckdb, so not on Android); Input BigQuery likewise uses the community `bigquery` extension.
- `apps/ixpipe_app`: the Baguette UI. `IxpipeApp.MainView` is the main window: home (workflows in `IXPIPE_HOME`, default `~/ixpipe`) and the canvas (ribbon, scrolling canvas with curved wires, properties panel driven by each tool's `fields/0`, results grid of the selected tool's first 50 rows after a run). `IxpipeApp.Theme` holds the colour tokens; every colour class must resolve to one (tested).
  - Rust is only for NIFs: platform glue, `IxpipeCore.Duck` (`apps/ixpipe_core/native/ixpipe_duckdb`, duckdb-rs `~1.20000` = DuckDB v2.0.0) and `IxpipeCore.Sqlite` (`native/ixpipe_sqlite`, rusqlite bundled). Never compile DuckDB: the NIF links a prebuilt `libduckdb` that ships beside it in `priv/native` (rpath `$ORIGIN`). Desktop builds download DuckDB's official library (libduckdb-sys's `download-lib`); Android links the one CI publishes as a release asset.

## Rules

- **TDD for every feature and fix**: write the failing test first, see it fail, then implement. Styling-only changes are exempt.
- **All tests are Elixir (ExUnit).**
  - Engine: `apps/ixpipe_core/test`. Test a tool on its own with `ctx = IxpipeCore.Context.new()`, inputs from `Table.new(ctx.db, "src", col: [...])`, and assertions on `Table.to_columns/1`.
  - UI: headless `Baguette.Test` in `apps/ixpipe_app/test`.
  - End-to-end UI: `Baguette.Playwright` (gpui-playwright) in `apps/ixpipe_app/test/e2e`, tagged `:playwright` and excluded by default.
  - QA: screenshot QA (`:qa`) and a seeded chaos monkey (`:chaos`) in `apps/ixpipe_app/test/qa`; headless fuzzing in `main_view_fuzz_test.exs`. See `.claude/skills/app-qa/SKILL.md`; run it after UI changes, before reporting done.
- Never create atoms from workflow input. Ports, ids and config keys stay strings.
- Runic hashes steps by their fn plus bound variables, so build step fns inline (see `IxpipeCore.step/2`). A fn passed in as a variable gets the same hash for every node.
- When recommending actions, give options A/B/C plus a recommendation. Ask when something is ambiguous.
- No PRs unless asked. PR descriptions are 1-2 lines plus the session link.

## Design language

ixpipe follows ixtable's design language
([tznc/ixtable `docs/decisions/design-language.md`](https://github.com/tznc/ixtable/blob/main/docs/decisions/design-language.md)).
`IxpipeApp.Components` implements it; screens compose those components, and a
one-off style is a bug. `design_rules_test.exs` enforces what can be checked.

- **Colour** (`IxpipeApp.Theme`): gpui-kit's greys plus one accent, the
  ixtable teal `#0DB9B6` with white text (links `#0A7C7A`). Colour carries
  meaning (selection, status, danger), never decoration. Status is a tint
  plus text (`<.callout>`, `<.status_badge>`), never text colour alone.
  Selection is a teal tint and border. Disabled is 40% opacity.
- **Type scale**: `<.title>` (one per view), `<.section>`, `<.body>`,
  `<.label>`, `<.caption>`. Raw `text-*` sizes and `font-*` weights are
  allowed only in `components.ex` (tested).
- **Buttons** (`<.button variant=…>`): `:primary` completes the task, at most
  one per view (tested); `:secondary` for everything else; `:quiet` in
  dense lists and toolbars; `:danger` for delete, remove, drop and reset
  (tested); `:link` for breadcrumbs. Label with a verb and an object
  ("Save workflow", "Run workflow").
- **Layout**: left-aligned; only empty states and dialogs are centred.
  Spacing on the 4px scale: `gap-1` in a control group, `gap-3` between
  fields, `gap-6` between sections, `p-4` in a card.
- **Feedback never moves the layout**: run results and modes are a callout
  over the canvas; transient success ("Saved sales.yaml") is a `<.toast>`
  top right that clears after 6 s; errors read "what happened. what to do."
- **Empty states**: every list or canvas that can be empty has one: a
  title, one sentence, at most one action (tested on home and canvas).
- **Ribbon** (`<.ribbon>`, `<.ribbon_group>`), as in ixtable after Access:
  a row of tabs over labelled command groups, under the canvas header.
  Home holds Edit (Undo, Redo) and View (zoom); In/Out, Preparation, Join,
  Parse and Transform hold the tools. Commands are `:quiet` small buttons with
  a lucide icon (`<.button icon="undo-2">`, ixtable's: Undo2, Redo2, ZoomIn,
  ZoomOut; each tool its own, an input and output sharing their format's)
  and a short noun ("CSV" in the Input group); zoom is icon-only with an
  `aria-label`. The group name is a caption beneath. Save (`save`) and Run
  (`play`) stay in the header, always visible.
- **Phone** (window under 640px wide, learnt from baguette's
  `phx-window-resize`): Save and Run icon-only in the header, the ribbon's
  rows scroll sideways, and Canvas / Properties / Results are panes of a
  `<.tab_bar>` at the bottom (selecting a tool shows Properties; a run with
  one selected shows Results). Controls outside the canvas's cards are
  `size: :touch` (at least 40px). Wider windows keep the desktop layout.
- **Shortcuts** (`phx-window-keydown` on the canvas; Ctrl or Cmd): Z undo,
  Shift+Z or Y redo, S save, Enter run, = and - zoom, 0 restore view. Each
  command's `title` tooltip names its shortcut ("Undo (Ctrl+Z)"; Cmd on
  macOS). Typing in a field fires none, and its own Ctrl+Z undoes its text.
- **Navigation**: drill-in uses `<.breadcrumb>` ("Workflows / sales.yaml"),
  not a Back button.
- **Words**: sentence case; tool names humanized ("Input CSV"); counts with
  correct plurals ("1 row", "4 rows"); dates relative within a week.

## Toolchain

- OTP 29.1.2 and Elixir 1.20.4 (match baguette's CI).
- Rust stable.
- Linux GPUI deps: see baguette's CI.
- Android: SDK 34 and NDK 27.2.12479018.

```sh
mix test                      # all apps
mix test apps/ixpipe_core/test
mix format --check-formatted

# End-to-end: a release with the host's playwright feature, under a display.
# Needs BAGUETTE_LIBERLANG (scripts/build-liberlang.sh in baguette) and that
# OTP install's bin on PATH.
BAGUETTE_HOST_FEATURES=playwright MIX_ENV=prod mix release ixpipe --overwrite
xvfb-run -a mix test --only playwright
```

Postgres tests (`:postgres`, excluded by default) need a local server with a
role `ixpipe` and database `ixpipe_test`; override with `IXPIPE_PG_HOST`,
`IXPIPE_PG_PORT`, `IXPIPE_PG_DATABASE`, `IXPIPE_PG_USER`.

```sh
apt-get install -y postgresql && service postgresql start
runuser -u postgres -- psql -c "CREATE ROLE ixpipe LOGIN PASSWORD 'ixpipe-test'"
runuser -u postgres -- psql -c "CREATE DATABASE ixpipe_test OWNER ixpipe"
PGPASSWORD=ixpipe-test mix test --only postgres
```

MySQL (`:mysql`) and SQL Server (`:mssql`) tests work the same way, with
`IXPIPE_MYSQL_*` / `MYSQL_PWD` and `IXPIPE_MSSQL_*` / `SQLCMDPASSWORD`
(user `sa`; the tests create `ixpipe_test`). SQL Server 2022's jammy package
installs on Ubuntu 24.04 with jammy's libldap-2.5-0 beside it.

```sh
apt-get install -y mysql-server && service mysql start
mysql -uroot -e "CREATE USER 'ixpipe'@'localhost' IDENTIFIED BY 'ixpipe-test';
  CREATE DATABASE ixpipe_test; GRANT ALL ON ixpipe_test.* TO 'ixpipe'@'localhost'"
MYSQL_PWD=ixpipe-test mix test --only mysql

# SQL Server: add https://packages.microsoft.com/ubuntu/22.04/mssql-server-2022, then
apt-get install -y mssql-server
runuser -u mssql -- env ACCEPT_EULA=Y MSSQL_PID=Developer \
  MSSQL_SA_PASSWORD='Ixpipe-test1' /opt/mssql/bin/sqlservr &
SQLCMDPASSWORD='Ixpipe-test1' mix test --only mssql

# S3 (`:s3`): any S3-compatible server; moto's needs no setup.
pip install 'moto[server]' && moto_server -p 5000 &
mix test --only s3   # IXPIPE_S3_ENDPOINT, default localhost:5000
```

## Connections

Saved in `connections.yaml` in the workflows home (`IxpipeCore.Connections`),
named by a tool's `connection` setting; the properties panel lists those of
the kinds the field takes (`kinds:` in `fields/0`). Secrets are never written
down: a setting ending in `_env` names the environment variable holding one.

| Type | Settings | Used by |
| --- | --- | --- |
| `postgres`, `mysql`, `sqlserver` | `host`, `port`, `database`, `username`, `password_env` (`sqlserver`: `ssl`) | Input/Output Postgres, MySQL, SQL Server |
| `sqlite` | `path` | Input/Output SQLite |
| `s3` | `key_id`, `secret_env`, `region`, `endpoint`, `session_token_env`, `url_style`, `use_ssl` | CSV, Parquet, JSON tools on `s3://` paths |
| `gcs` | `key_id`, `secret_env` (an HMAC key) | the same on `gs://` |
| `azure` | `connection_string_env` | the same on `az://` and `abfss://` |
| `bigquery` | `project`, `service_account_path` or `access_token_env` (else gcloud's application default credentials) | Input BigQuery (DuckDB's community `bigquery` extension; `:bigquery` test needs `IXPIPE_BQ_PROJECT`) |

A cloud connection becomes a DuckDB secret scoped to the path's bucket, for
that run only. Outputs replace a table (default) or append, creating it if
missing; DuckDB types map to the server's (`IxpipeCore.Server.column_type/2`).
Postgres loads with `COPY`, MySQL and SQL Server with batched `INSERT`s.

`IXPIPE_WORKFLOW` opens a workflow straight onto the canvas.
