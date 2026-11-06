defmodule IxpipeCore.Tools.FuzzyMatch do
  @moduledoc """
  Finds records whose `field` values are alike, as Alteryx's Fuzzy Match.
  With only `in` connected it dedupes (each pair once); with the optional
  `match` input too, it matches each `in` record against `match`'s.

  Values are compared lower-cased by `method`: `jaro_winkler` (default),
  `levenshtein` (1 - edits / longer length) or `jaccard` (shared
  characters), scored 0 to 100. Pairs scoring at least `threshold`
  (default 80) come out as `id`, `match_id` (the records' `id` column, or
  their row numbers from 1), `value`, `match_value` and `score` (one
  decimal), by `id` then `match_id`. With `clusters`, a `cluster` number
  groups pairs that connect through shared records.

  Every pair is compared, so time grows with the product of the inputs'
  row counts: above 10 million pairs the node warns.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @impl true
  def inputs, do: ["in", "match"]

  @impl true
  def optional_inputs, do: ["match"]

  @impl true
  def fields,
    do: [
      %{key: "field", label: "Match on", type: :string, hint: "A text column"},
      %{
        key: "method",
        label: "Method",
        type: :choice,
        options: ~w(jaro_winkler levenshtein jaccard),
        default: "jaro_winkler",
        optional: true
      },
      %{
        key: "threshold",
        label: "Threshold (%)",
        type: :integer,
        hint: "0 to 100",
        default: 80,
        optional: true
      },
      %{
        key: "id",
        label: "Record id",
        type: :string,
        hint: "Leave empty to number the rows",
        optional: true
      },
      %{
        key: "clusters",
        label: "Group into clusters",
        type: :bool,
        default: false,
        optional: true
      }
    ]

  @impl true
  def run(%{"in" => t} = inputs, %{"field" => field} = config, ctx) do
    threshold = config["threshold"] || 80

    unless is_integer(threshold) and threshold in 0..100,
      do: raise("Threshold must be 0 to 100. Enter a percentage.")

    side = fn table ->
      id = if c = config["id"], do: ident(c), else: "row_number() OVER (ORDER BY rowid)"

      "SELECT #{id} AS id, rowid AS __rid, CAST(#{ident(field)} AS VARCHAR) AS value " <>
        "FROM #{Table.ref(table)} WHERE #{ident(field)} IS NOT NULL"
    end

    # Deduping, both sides are the same records, so they share a key prefix.
    {b, pair, b_key} =
      case inputs do
        %{"match" => m} -> {side.(m), "true", "1:"}
        _ -> {side.(t), "a.__rid < b.__rid", "0:"}
      end

    warn_if_slow(ctx, t, inputs["match"], field)

    score = "round(100 * #{similarity(config["method"], "lower(a.value)", "lower(b.value)")}, 1)"

    # Prefixed, so the CTEs don't shadow an input table (named for its node).
    pairs = """
    WITH RECURSIVE __fm_a AS (#{side.(t)}), __fm_b AS (#{b}),
    __fm_pairs AS (
      SELECT * FROM (
        SELECT a.id, b.id AS match_id, a.value, b.value AS match_value, #{score} AS score,
          a.__rid AS __a, b.__rid AS __b
        FROM __fm_a a JOIN __fm_b b ON #{pair}
      ) WHERE score >= #{threshold}
    )
    """

    if config["clusters"],
      do: Context.sql(ctx, pairs <> clusters(b_key)),
      else:
        Context.sql(
          ctx,
          pairs <> "SELECT * EXCLUDE (__a, __b) FROM __fm_pairs ORDER BY id, match_id"
        )
  end

  # Above this many pairs a run takes long enough to notice.
  @slow_pairs 10_000_000

  defp warn_if_slow(ctx, t, match, field) do
    present = fn table ->
      %{rows: [[n]]} =
        Table.query!(table.db, "SELECT count(#{ident(field)}) FROM #{Table.ref(table)}")

      n
    end

    n = present.(t)
    pairs = if match, do: n * present.(match), else: div(n * (n - 1), 2)

    if pairs > @slow_pairs,
      do:
        Context.warn(
          ctx,
          "Comparing #{delimit(pairs)} pairs of records is slow. " <>
            "Filter the inputs first, or match fewer records at a time."
        )
  end

  defp delimit(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp similarity(method, x, y) do
    case method || "jaro_winkler" do
      "jaro_winkler" -> "jaro_winkler_similarity(#{x}, #{y})"
      "levenshtein" -> "(1 - levenshtein(#{x}, #{y}) / greatest(length(#{x}), length(#{y}), 1))"
      "jaccard" -> "jaccard(#{x}, #{y})"
      other -> raise "Unknown method #{other}. Choose jaro_winkler, levenshtein or jaccard."
    end
  end

  # Connected components over the pairs, records keyed by side and row:
  # each record's root is the least record it reaches.
  defp clusters(b_key) do
    key = fn side, col -> "'#{side}' || lpad(#{col}::VARCHAR, 20, '0')" end

    """
    , __fm_edges AS (SELECT #{key.("0:", "__a")} AS x, #{key.(b_key, "__b")} AS y FROM __fm_pairs),
    __fm_links AS (SELECT x, y FROM __fm_edges UNION SELECT y, x FROM __fm_edges),
    __fm_reach(node, root) AS (
      SELECT x, x FROM __fm_links
      UNION
      SELECT l.y, r.root FROM __fm_reach r JOIN __fm_links l ON l.x = r.node
    ),
    __fm_roots AS (SELECT node, min(root) AS root FROM __fm_reach GROUP BY node)
    SELECT p.* EXCLUDE (__a, __b), dense_rank() OVER (ORDER BY r.root) AS cluster
    FROM __fm_pairs p JOIN __fm_roots r ON r.node = #{key.("0:", "p.__a")}
    ORDER BY p.id, p.match_id
    """
  end
end
