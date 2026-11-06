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
  row counts.
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

    score = "round(100 * #{similarity(config["method"], "lower(a.value)", "lower(b.value)")}, 1)"

    pairs = """
    WITH RECURSIVE a AS (#{side.(t)}), b AS (#{b}),
    pairs AS (
      SELECT * FROM (
        SELECT a.id, b.id AS match_id, a.value, b.value AS match_value, #{score} AS score,
          a.__rid AS __a, b.__rid AS __b
        FROM a JOIN b ON #{pair}
      ) WHERE score >= #{threshold}
    )
    """

    if config["clusters"],
      do: Context.sql(ctx, pairs <> clusters(b_key)),
      else:
        Context.sql(
          ctx,
          pairs <> "SELECT * EXCLUDE (__a, __b) FROM pairs ORDER BY id, match_id"
        )
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
    , edges AS (SELECT #{key.("0:", "__a")} AS x, #{key.(b_key, "__b")} AS y FROM pairs),
    links AS (SELECT x, y FROM edges UNION SELECT y, x FROM edges),
    reach(node, root) AS (
      SELECT x, x FROM links
      UNION
      SELECT links.y, reach.root FROM reach JOIN links ON links.x = reach.node
    ),
    roots AS (SELECT node, min(root) AS root FROM reach GROUP BY node)
    SELECT p.* EXCLUDE (__a, __b), dense_rank() OVER (ORDER BY r.root) AS cluster
    FROM pairs p JOIN roots r ON r.node = #{key.("0:", "p.__a")}
    ORDER BY p.id, p.match_id
    """
  end
end
