defmodule IxpipeCore.Tools.Join do
  @moduledoc """
  Joins `left` and `right` on key columns. Outputs, as Alteryx's J, L and R:
  `joined` (per `how`), `left` (left rows with no match) and `right` (right
  rows with no match). Config: `on`, optional `how` (`inner` (default),
  `left`, `outer`, `cross`).
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @impl true
  def inputs, do: ["left", "right"]

  @impl true
  def fields,
    do: [
      %{key: "on", label: "Join on", type: :list, hint: "Columns both inputs share"},
      %{
        key: "how",
        label: "Join type",
        type: :choice,
        options: ["inner", "left", "outer", "cross"],
        optional: true
      }
    ]

  @impl true
  def outputs, do: ["joined", "left", "right"]

  @impl true
  def run(%{"left" => left, "right" => right}, %{"on" => on} = config, ctx) do
    how = config["how"] || "inner"
    if how != "cross", do: warn_key_types(ctx, left, right, on)
    l = Table.ref(left)
    r = Table.ref(right)
    keys = Enum.map_join(on, ", ", &ident/1)
    left_cols = Table.columns(left)

    # The right side's other columns; a name the left already has gets _right.
    rights =
      for col <- Table.columns(right), how == "cross" or col not in on do
        if col in left_cols,
          do: "r.#{ident(col)} AS #{ident(col <> "_right")}",
          else: "r.#{ident(col)}"
      end

    lefts =
      for col <- left_cols,
          do: if(how != "cross" and col in on, do: ident(col), else: "l.#{ident(col)}")

    columns = Enum.join(lefts ++ rights, ", ")

    joined =
      case how do
        "cross" -> "SELECT #{columns} FROM #{l} l CROSS JOIN #{r} r"
        "outer" -> "SELECT #{columns} FROM #{l} l FULL JOIN #{r} r USING (#{keys})"
        "left" -> "SELECT #{columns} FROM #{l} l LEFT JOIN #{r} r USING (#{keys})"
        _ -> "SELECT #{columns} FROM #{l} l JOIN #{r} r USING (#{keys})"
      end

    %{
      "joined" => Context.sql(ctx, "joined", joined),
      "left" =>
        Context.sql(ctx, "left", "SELECT l.* FROM #{l} l ANTI JOIN #{r} r USING (#{keys})"),
      "right" =>
        Context.sql(ctx, "right", "SELECT r.* FROM #{r} r ANTI JOIN #{l} l USING (#{keys})")
    }
  end

  # Keys of different kinds (a number and text) match nothing, or fail to
  # compare at all; two kinds of number compare fine.
  defp warn_key_types(ctx, left, right, on) do
    {lt, rt} = {Table.dtypes(left), Table.dtypes(right)}

    for key <- on, lt[key] && rt[key], kind(lt[key]) != kind(rt[key]) do
      Context.warn(
        ctx,
        ~s(Join key "#{key}" is #{lt[key]} on the left and #{rt[key]} on the right. ) <>
          "Convert one with a Formula, e.g. CAST(#{ident(key)} AS #{lt[key]}), so the keys match."
      )
    end
  end

  @numbers ~w(TINYINT SMALLINT INTEGER BIGINT HUGEINT UTINYINT USMALLINT UINTEGER UBIGINT
              UHUGEINT FLOAT DOUBLE REAL)
  defp kind(type) do
    cond do
      type in @numbers or String.starts_with?(type, "DECIMAL") -> :number
      String.starts_with?(type, "TIMESTAMP") or type == "DATE" -> :time
      true -> type
    end
  end
end
