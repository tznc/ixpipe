defmodule IxpipeCore.Tools.RecordId do
  @moduledoc """
  Numbers the rows of `in`, in order, in a new column. Config, all
  optional: `name` (default `RecordID`), `start` (the first row's number,
  default 1) and `position` (`first` (default) or `last` column).
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{key: "name", label: "Column name", type: :string, default: "RecordID", optional: true},
      %{key: "start", label: "Start at", type: :integer, default: 1, optional: true},
      %{
        key: "position",
        label: "Position",
        type: :choice,
        options: ~w(first last),
        default: "first",
        optional: true
      }
    ]

  @impl true
  def run(%{"in" => t}, config, ctx) do
    start = config["start"] || 1

    unless is_integer(start), do: raise("Start at must be a whole number. Enter one.")

    id =
      "(row_number() OVER (ORDER BY rowid) + #{start - 1}) AS #{ident(config["name"] || "RecordID")}"

    columns = if config["position"] == "last", do: "*, #{id}", else: "#{id}, *"
    Context.sql(ctx, "SELECT #{columns} FROM #{Table.ref(t)} ORDER BY rowid")
  end
end
