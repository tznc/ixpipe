defmodule IxpipeCore.Tools.MacroInput do
  @moduledoc """
  An input port of a macro (see `IxpipeCore.Macro`): `name` (the node's id
  when unset) and the `columns` it expects. Used as a tool, the macro feeds
  it the table wired to that port; run on its own, it reads its sample data
  (a CSV `path`), or is empty with its expected columns.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1, literal: 1]

  @impl true
  def inputs, do: []

  @impl true
  def fields,
    do: [
      %{
        key: "name",
        label: "Port name",
        type: :string,
        optional: true,
        hint: "Defaults to this tool's id"
      },
      %{
        key: "columns",
        label: "Expected columns",
        type: :list,
        optional: true,
        hint: "Columns the input must have, e.g. id, amount"
      },
      %{
        key: "path",
        label: "Sample data",
        type: :path,
        accept: ["csv"],
        optional: true,
        hint: "A CSV to test the macro with on its own"
      }
    ]

  @impl true
  def run(_inputs, %{"_bound" => %Table{} = table} = config, ctx) do
    expected = config["columns"] || []

    case expected -- Table.columns(table) do
      [] ->
        Context.sql(ctx, "SELECT * FROM #{Table.ref(table)}")

      missing ->
        raise "expects the column#{if length(missing) > 1, do: "s"} #{Enum.join(missing, ", ")}; " <>
                "the input has #{Enum.join(Table.columns(table), ", ")}"
    end
  end

  def run(_inputs, %{"path" => path}, ctx) when is_binary(path),
    do: Context.sql(ctx, "SELECT * FROM read_csv(#{literal(path)})")

  def run(_inputs, %{"columns" => [_ | _] = columns}, ctx),
    do:
      Context.sql(
        ctx,
        "SELECT " <> Enum.map_join(columns, ", ", &"NULL::VARCHAR AS #{ident(&1)}") <> " LIMIT 0"
      )

  def run(_inputs, _config, _ctx),
    do:
      raise(
        "has no data on its own. Give it sample data or expected columns to run the macro alone."
      )
end
