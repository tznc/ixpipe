defmodule IxpipeCore.DuckRun do
  @moduledoc """
  Runs a workflow on DuckDB (spike): every node becomes a CTE, so DuckDB
  plans the whole workflow as one query and spills to disk past
  `memory_limit`. Results are keyed like `IxpipeCore.run/1`.

  Supports input_csv, filter, formula and summarize.
  """
  alias IxpipeCore.{Duck, Spec, Tools}
  import Duck, only: [ident: 1, literal: 1]

  @spec run(Spec.t(), keyword()) ::
          {:ok, %{String.t() => Explorer.DataFrame.t()}} | {:error, term()}
  def run(%Spec{} = spec, opts \\ []) do
    settings = Keyword.get(opts, :settings, [])

    with {:ok, ctes} <- compile(spec, settings) do
      keys = opts[:only] || Enum.map(ctes, &elem(&1, 0))

      with_clause =
        "WITH " <> Enum.map_join(ctes, ",\n", fn {k, sql} -> "#{ident(k)} AS (#{sql})" end)

      Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
        case Duck.frame("#{with_clause}\nSELECT * FROM #{ident(key)}", settings) do
          {:ok, df} -> {:cont, {:ok, Map.put(acc, key, df)}}
          {:error, message} -> {:halt, {:error, {:node_failed, key, message}}}
        end
      end)
    end
  end

  # [{key, sql}] in topological order; a node with several outputs gives one
  # CTE per output, keyed `node.output`.
  defp compile(spec, settings) do
    Enum.reduce_while(spec.nodes, {:ok, []}, fn node, {:ok, ctes} ->
      source = fn port ->
        case Spec.source(node.inputs[port]) do
          {id, nil} -> ident(id)
          {id, out} -> ident("#{id}.#{out}")
        end
      end

      columns = fn sql ->
        {:ok, df} = Duck.frame(with_ctes(ctes, "SELECT * FROM (#{sql}) LIMIT 0"), settings)
        Explorer.DataFrame.names(df)
      end

      case sql(Tools.name(node.tool), node.config, source, columns) do
        {:error, _} = error ->
          {:halt, error}

        outs when is_list(outs) ->
          {:cont, {:ok, ctes ++ Enum.map(outs, fn {out, q} -> {key(node.id, out), q} end)}}
      end
    end)
  end

  defp key(id, nil), do: id
  defp key(id, out), do: "#{id}.#{out}"

  defp with_ctes([], sql), do: sql

  defp with_ctes(ctes, sql),
    do:
      "WITH " <>
        Enum.map_join(ctes, ",\n", fn {k, q} -> "#{ident(k)} AS (#{q})" end) <> "\n" <> sql

  defp sql("input_csv", %{"path" => path}, _, _),
    do: [{nil, "SELECT * FROM read_csv(#{literal(path)})"}]

  defp sql("filter", %{"expr" => expr}, source, _) do
    [
      {"true", "SELECT * FROM #{source.("in")} WHERE (#{expr})"},
      {"false", "SELECT * FROM #{source.("in")} WHERE NOT COALESCE((#{expr}), FALSE)"}
    ]
  end

  defp sql("formula", %{"formulas" => formulas}, source, columns) do
    query =
      Enum.reduce(formulas, "SELECT * FROM #{source.("in")}", fn %{"as" => as, "expr" => expr},
                                                                 q ->
        column = "(#{expr}) AS #{ident(as)}"

        if as in columns.(q),
          do: "SELECT * REPLACE (#{column}) FROM (#{q})",
          else: "SELECT *, #{column} FROM (#{q})"
      end)

    [{nil, query}]
  end

  defp sql("summarize", %{"group_by" => group_by, "aggregates" => aggregates}, source, _) do
    groups = Enum.map_join(group_by, ", ", &ident/1)

    aggs =
      Enum.map_join(aggregates, ", ", fn %{"column" => c, "op" => op, "as" => as} ->
        "#{aggregate(op, ident(c))} AS #{ident(as)}"
      end)

    [{nil, "SELECT #{groups}, #{aggs} FROM #{source.("in")} GROUP BY #{groups}"}]
  end

  defp sql(tool, _, _, _), do: {:error, {:unsupported, tool}}

  defp aggregate("mean", c), do: "avg(#{c})"
  defp aggregate("n_distinct", c), do: "count(DISTINCT #{c})"
  defp aggregate(op, c) when op in ~w(sum min max count), do: "#{op}(#{c})"
end
