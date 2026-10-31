defmodule IxpipeCore.Tools.Select do
  @moduledoc """
  Chooses, renames, retypes and reorders columns, as Alteryx's Select does.

  Config `columns` lists columns in the order to output them. Each entry is
  a column name (kept as is) or a map: `name`, and optionally `keep: false`
  to drop it, `rename` and `type`, a DuckDB type (`BIGINT`, `DECIMAL(18,2)`,
  …) to cast it to with `TRY_CAST`: a value that does not convert becomes
  NULL, and the table's warnings say how many did.

  `new_columns` (`keep` or `drop`) decides the input's columns that are not
  listed, after the listed ones: `keep` by default, but `drop` for a list of
  plain names (the original Select, which kept exactly the listed columns).
  A listed column missing from the input is skipped, with a warning.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @types ~w(VARCHAR BIGINT INTEGER SMALLINT TINYINT HUGEINT UBIGINT UINTEGER USMALLINT UTINYINT
            DOUBLE FLOAT REAL DECIMAL DATE TIME TIMESTAMP TIMESTAMPTZ BOOLEAN BLOB UUID JSON)

  @doc "The types an editor offers first."
  def common_types,
    do: ~w[VARCHAR BIGINT DOUBLE DECIMAL(18,2) DATE TIMESTAMP BOOLEAN]

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{key: "columns", label: "Columns", type: :select, optional: true},
      %{
        key: "new_columns",
        label: "New columns",
        type: :choice,
        options: ["keep", "drop"],
        optional: true,
        hint: "Columns the list doesn't name, such as ones the input gains later"
      }
    ]

  @doc "Whether `type` is a DuckDB type Select casts to (any case, `DECIMAL(p,s)` too)."
  @spec type?(String.t()) :: boolean()
  def type?(type) do
    case Regex.run(~r/^\s*([A-Za-z]+)\s*(\(\s*\d+\s*(,\s*\d+\s*)?\))?\s*$/, type) do
      [_, name] -> String.upcase(name) in @types
      [_, name | _] -> String.upcase(name) == "DECIMAL"
      nil -> false
    end
  end

  @doc "What happens to columns the config does not list: `keep` or `drop`."
  @spec new_columns(map()) :: String.t()
  def new_columns(config) do
    cond do
      config["new_columns"] in ["keep", "drop"] -> config["new_columns"]
      legacy?(config["columns"]) -> "drop"
      true -> "keep"
    end
  end

  @impl true
  def run(%{"in" => t}, config, ctx) do
    rows = rows(config, Table.schema(t))
    {missing, rows} = Enum.split_with(rows, & &1["missing"])
    kept = Enum.filter(rows, & &1["keep"])

    Enum.each(kept, fn %{"type" => type} ->
      if type && !type?(type),
        do: raise("#{type} is not a type. Use one of " <> Enum.join(common_types(), ", ") <> ".")
    end)

    names = Enum.map(kept, &out_name/1)

    if kept == [], do: raise("No columns are kept. Keep at least one column.")

    if dup = names |> Enum.frequencies() |> Enum.find(fn {_, n} -> n > 1 end),
      do: raise("Two columns are named #{elem(dup, 0)}. Rename one of them.")

    select =
      Enum.map_join(kept, ", ", fn %{"name" => name} = row ->
        value =
          if row["type"], do: "TRY_CAST(#{ident(name)} AS #{row["type"]})", else: ident(name)

        "#{value} AS #{ident(out_name(row))}"
      end)

    table = Context.sql(ctx, "SELECT #{select} FROM #{Table.ref(t)}")

    skipped =
      for %{"name" => name} <- missing, do: "#{name} is not in the input, so it was skipped."

    %{table | warnings: skipped ++ cast_warnings(t, Enum.filter(kept, & &1["type"]))}
  end

  defp out_name(row), do: row["rename"] || row["name"]

  # How many non-NULL values each cast turned into NULL.
  defp cast_warnings(_t, []), do: []

  defp cast_warnings(%Table{db: db} = t, casts) do
    counts =
      Enum.map_join(casts, ", ", fn %{"name" => name, "type" => type} ->
        "count(*) FILTER (WHERE #{ident(name)} IS NOT NULL AND TRY_CAST(#{ident(name)} AS #{type}) IS NULL)"
      end)

    %{rows: [row]} = Table.query!(db, "SELECT #{counts} FROM #{Table.ref(t)}")

    for {%{"name" => name, "type" => type}, n} <- Enum.zip(casts, row), n > 0 do
      if n == 1,
        do: "#{name}: 1 value couldn't become #{type} and is now NULL.",
        else: "#{name}: #{n} values couldn't become #{type} and are now NULL."
    end
  end

  ## The editor

  @doc """
  The rows an editor shows for `config` over an input `schema`
  (`[{name, type}]`): the listed columns in order, then the input's other
  columns, kept or not by `new_columns/1`. Each row has `name`, `keep`,
  `rename` and `type` (nil when unchanged), `input_type` (nil when the
  column is not in the input), `new` (not listed) and `missing` (listed
  but not in the input).
  """
  @spec rows(map(), [{String.t(), String.t()}]) :: [map()]
  def rows(config, schema) do
    types = Map.new(schema)
    listed = Enum.map(config["columns"] || [], &entry/1)
    names = MapSet.new(listed, & &1["name"])
    keep_new = new_columns(config) == "keep"

    listed_rows =
      for e <- listed do
        %{
          "name" => e["name"],
          "keep" => e["keep"] != false,
          "rename" => e["rename"],
          "type" => e["type"] && String.upcase(e["type"]),
          "input_type" => types[e["name"]],
          "new" => false,
          "missing" => not Map.has_key?(types, e["name"])
        }
      end

    new_rows =
      for {name, type} <- schema, name not in names do
        %{
          "name" => name,
          "keep" => keep_new,
          "rename" => nil,
          "type" => nil,
          "input_type" => type,
          "new" => true,
          "missing" => false
        }
      end

    listed_rows ++ new_rows
  end

  @doc """
  `config` with row `index` (of `rows/2`) changed by `changes` (`keep`,
  `rename`, `type`). The list is written out in full, as the editor showed
  it, with `new_columns` kept. A rename to the column's own name, or a type
  equal to its input type, clears it.
  """
  @spec edit(map(), [{String.t(), String.t()}], non_neg_integer(), map()) :: map()
  def edit(config, schema, index, changes) do
    rows = rows(config, schema)

    rows =
      List.update_at(rows, index, fn row ->
        row = Map.merge(row, changes)
        rename = row["rename"] && String.trim(row["rename"])
        type = row["type"] && String.trim(row["type"])

        %{
          row
          | "rename" => if(rename not in [nil, "", row["name"]], do: rename),
            "type" =>
              if(type not in [nil, ""] and String.upcase(type) != row["input_type"], do: type)
        }
      end)

    write(config, rows)
  end

  @doc "`config` with row `index` swapped with the row `by` (-1 or 1) away, if there is one."
  @spec move(map(), [{String.t(), String.t()}], non_neg_integer(), -1 | 1) :: map()
  def move(config, schema, index, by) do
    rows = rows(config, schema)
    other = index + by

    if other < 0 or other >= length(rows) do
      config
    else
      a = Enum.at(rows, index)
      b = Enum.at(rows, other)
      write(config, rows |> List.replace_at(index, b) |> List.replace_at(other, a))
    end
  end

  defp write(config, rows) do
    columns =
      for row <- rows do
        [
          {"name", row["name"]},
          {"keep", if(!row["keep"], do: false)},
          {"rename", row["rename"]},
          {"type", row["type"]}
        ]
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
        |> Map.new()
      end

    config
    |> Map.put("columns", columns)
    |> Map.put("new_columns", new_columns(config))
  end

  defp entry(name) when is_binary(name), do: %{"name" => name}
  defp entry(%{"name" => name} = e), do: Map.put(e, "name", to_string(name))

  defp legacy?(columns),
    do: is_list(columns) and columns != [] and Enum.all?(columns, &is_binary/1)
end
