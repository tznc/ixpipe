defmodule IxpipeCore.Tools.Tile do
  @moduledoc """
  Assigns each row of `in` a tile, as Alteryx's Tile: `Tile_Num`, and
  `Tile_SequenceNum`, the row's place within its tile. Rows keep their
  order. Config: `method`, and per method:

    * `equal_records`: `tiles` tiles of (nearly) as many rows, in row order
      or sorted by the optional `column`.
    * `equal_sum`: `tiles` tiles whose sums of `column` are about equal,
      sorting by `column` ascending.
    * `manual`: `cutoffs`, ascending numbers: tile 1 is `column` up to the
      first cut-off, tile 2 up to the second, and so on.
    * `smart`: by standard deviations of `column` from its mean: 0
      (`Average`, within one), 1 or -1 (`Above average`, `Below average`,
      within two), 2 or -2 (`High`, `Low`), with `Tile_Name`.

  With `group_by`, tiles are made within each group.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{
        key: "method",
        label: "Method",
        type: :choice,
        options: ~w(equal_records equal_sum manual smart)
      },
      %{
        key: "column",
        label: "Column",
        type: :string,
        hint: "The column to tile by",
        optional: true
      },
      %{key: "tiles", label: "Number of tiles", type: :integer, optional: true},
      %{
        key: "cutoffs",
        label: "Cut-offs",
        type: :list,
        hint: "Ascending, e.g. 10, 50, 100",
        optional: true
      },
      %{key: "group_by", label: "Group by", type: :list, optional: true}
    ]

  @impl true
  def run(%{"in" => t}, %{"method" => method} = config, ctx) do
    groups = config["group_by"] || []

    partition =
      if groups == [], do: "", else: "PARTITION BY #{Enum.map_join(groups, ", ", &ident/1)} "

    {tile, extra} = tile(method, config, partition)

    sequence = Enum.map_join(groups ++ ["Tile_Num"], ", ", &ident/1)

    Context.sql(ctx, """
    WITH base AS (SELECT *, rowid AS __rid FROM #{Table.ref(t)}),
    tiled AS (SELECT *, #{tile} AS Tile_Num FROM base)
    SELECT * EXCLUDE (__rid),
      row_number() OVER (PARTITION BY #{sequence} ORDER BY __rid) AS Tile_SequenceNum#{extra}
    FROM tiled ORDER BY __rid
    """)
  end

  defp tile("equal_records", config, partition) do
    order = if c = config["column"], do: "#{ident(c)}, __rid", else: "__rid"
    {"ntile(#{tiles!(config)}) OVER (#{partition}ORDER BY #{order})", ""}
  end

  defp tile("equal_sum", config, partition) do
    c = ident(column!(config, "equal_sum"))
    n = tiles!(config)
    w = "(#{partition}ORDER BY #{c}, __rid ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)"
    total = "sum(#{c}) OVER (#{partition})"
    # Where the row's share starts along the total, in tiles.
    start = "(sum(#{c}) OVER #{w} - #{c}) / nullif(#{total}, 0) * #{n}"
    {"least(#{n}, greatest(1, CAST(floor(coalesce(#{start}, 0)) AS BIGINT) + 1))", ""}
  end

  defp tile("manual", config, _partition) do
    c = ident(column!(config, "manual"))

    cutoffs =
      Enum.map(config["cutoffs"] || [], fn cut ->
        case Float.parse(to_string(cut)) do
          {_, ""} -> to_string(cut)
          _ -> raise "Cut-off #{cut} is not a number. Enter numbers, e.g. 10, 50."
        end
      end)

    if cutoffs == [], do: raise("Manual tiles need cut-offs. Enter them, e.g. 10, 50.")

    whens =
      cutoffs
      |> Enum.with_index(1)
      |> Enum.map_join(" ", fn {cut, i} -> "WHEN #{c} <= #{cut} THEN #{i}" end)

    {"CASE WHEN #{c} IS NULL THEN NULL #{whens} ELSE #{length(cutoffs) + 1} END", ""}
  end

  defp tile("smart", config, partition) do
    c = ident(column!(config, "smart"))

    z =
      "(#{c} - avg(#{c}) OVER (#{partition})) / nullif(stddev_samp(#{c}) OVER (#{partition}), 0)"

    tile =
      "CASE WHEN #{c} IS NULL THEN NULL ELSE " <>
        "CAST(sign(coalesce(#{z}, 0)) * least(2, ceil(abs(coalesce(#{z}, 0))) - 1) AS BIGINT) END"

    # Exactly on one sd is still within it: ceil(1) - 1 = 0.
    name = """
    , CASE Tile_Num WHEN 0 THEN 'Average' WHEN 1 THEN 'Above average' WHEN -1 THEN 'Below average'
      WHEN 2 THEN 'High' WHEN -2 THEN 'Low' END AS Tile_Name
    """

    {tile, name}
  end

  defp tile(method, _config, _partition),
    do: raise("Unknown tile method #{method}. Choose equal_records, equal_sum, manual or smart.")

  defp tiles!(config) do
    case config["tiles"] do
      n when is_integer(n) and n > 0 -> n
      _ -> raise "This method needs a number of tiles. Enter one, e.g. 4."
    end
  end

  defp column!(config, method) do
    config["column"] || raise "The #{method} method needs a column. Choose the column to tile by."
  end
end
