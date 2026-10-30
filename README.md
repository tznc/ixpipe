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

Tools: `input_csv`, `select`, `sort`, `join`, `summarize`, `output_csv`
(`filter` and `formula` coming).

Built with Elixir, [Runic](https://hex.pm/packages/runic) (DAG engine),
[Explorer](https://hex.pm/packages/explorer) (dataframes) and
[baguette](https://github.com/ziinc/baguette) (GPUI rendering in a Tauri host).
See [AGENTS.md](AGENTS.md) for development.
