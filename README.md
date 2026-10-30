# ixpipe

An open-source alternative to Alteryx: build data workflows as a DAG of tools
on a canvas, and run them on desktop (Linux first) and mobile (Android, iOS).

Workflows are YAML:

```yaml
name: sales
nodes:
  - {id: orders, tool: input_csv, config: {path: orders.csv}}
  - {id: customers, tool: input_csv, config: {path: customers.csv}}
  - id: joined
    tool: join
    inputs: {left: orders, right: customers}
    config: {on: [customer_id]}
  - id: totals
    tool: summarize
    inputs: {in: joined}
    config:
      group_by: [name]
      aggregates: [{column: amount, op: sum, as: total}]
  - {id: out, tool: output_csv, inputs: {in: totals}, config: {path: totals.csv}}
```

Tools: `input_csv`, `select`, `filter`, `formula`, `sort`, `join`,
`summarize`, `output_csv`.

`filter` and `formula` take [Polars SQL](https://docs.pola.rs/api/python/stable/reference/sql/)
expressions over the input table `df`:

```yaml
- {id: big, tool: filter, inputs: {in: orders}, config: {expr: "amount > 10 AND region = 'eu'"}}
- id: priced
  tool: formula
  inputs: {in: big}
  config:
    formulas:
      - {as: taxed, expr: "amount * 1.1"}
      - {as: region, expr: "UPPER(region)"}   # replaces the column
```

Expressions are full SQL: subqueries and table functions such as
`read_csv('other.csv')` work, so only run workflows you trust.

## Headless runs

Run or check a workflow without the app, from a checkout or a release:

```sh
mix ixpipe.run sales.yaml [--json] [--output-dir DIR]
mix ixpipe.validate sales.yaml

_build/prod/rel/ixpipe/bin/ixpipe-run run sales.yaml --json
```

Each tool's row count is printed (or one JSON object with `--json`). Exit
codes: 0 succeeded, 1 the workflow failed, 2 bad usage. Relative paths
resolve against the workflow's directory; `--output-dir` redirects output
tools' relative paths.

Schedule runs with cron or a systemd timer, for example nightly at 02:00:

```cron
0 2 * * * /opt/ixpipe/bin/ixpipe-run run /data/sales.yaml --output-dir /data/out >> /var/log/ixpipe.log 2>&1
```

Built with Elixir, [Runic](https://hex.pm/packages/runic) (DAG engine),
[Explorer](https://hex.pm/packages/explorer) (dataframes) and
[baguette](https://github.com/ziinc/baguette) (GPUI rendering in a Tauri host).
See [AGENTS.md](AGENTS.md) for development.
