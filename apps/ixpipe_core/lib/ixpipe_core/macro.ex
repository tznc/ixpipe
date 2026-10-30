defmodule IxpipeCore.Macro do
  @moduledoc """
  Macros: workflows reused as tools, as in Alteryx.

  A macro is a workflow file with Macro input tools (its input ports, by
  `name` or id, optionally with the `columns` they expect) and Macro output
  tools (its output ports). An optional `macro:` header declares its type
  and parameters:

      name: Big orders
      macro:
        type: standard            # standard (default), batch or iterative
        parameters:
          - {name: threshold, type: integer, label: Threshold, default: 10}
      nodes:
        - {id: rows, tool: macro_input, config: {columns: [amount]}}
        - {id: f, tool: filter, inputs: {in: rows}, config: {expr: "amount > {{threshold}}"}}
        - {id: big, tool: macro_output, inputs: {in: f.true}}

  Another workflow uses it as a node with `tool: macro`, its `path`
  (relative to that workflow's folder) and its parameters in `config`:

      - {id: m, tool: macro, inputs: {rows: orders}, config: {path: big.yaml, threshold: 20}}

  The node's inputs and outputs are the macro's ports; its settings are
  `path` then the parameters, as fields (`type` is one of string, integer,
  bool, choice with `options`, list, expr or path; a parameter without a
  `default` is required).

  ## Parameters

  `{{name}}` in an inner tool's setting is the parameter's value. In SQL
  settings (`:expr` and `:formulas` fields) it is a SQL literal (`'eu'`,
  `10`, `TRUE`, a list as `'a', 'b'`), so a value can never change the
  query. Elsewhere it is the value as text, and a setting that is only
  `{{name}}` takes the value with its type. A reference to an unknown
  parameter fails to load.

  ## Running

  The inner workflow runs through Runic in the same run's database, its
  tables named under the node (`m/f.true`), and a failure names the inner
  tool (`m/f`). A macro may use other macros, each `path` relative to its
  own file; one that uses itself, directly or not, is rejected.

  - **Batch** (`type: batch`): the node gets a `control` input. The macro
    runs once per distinct combination of the control's columns that name
    parameters, those values overriding the node's, and each output is the
    batches' outputs unioned by name.
  - **Iterative** (`type: iterative`, `iterate: {input: rows, output: again,
    max: 100}`): the macro runs again with the `output` port's rows fed into
    the `input` port, until that output is empty or `max` iterations ran
    (the node's `max_iterations` can lower or raise it). The iteration
    output holds the last iteration's rows; every other output unions the
    iterations' by name; the extra `iterations` output reports how many ran.
  """

  alias IxpipeCore.{Config, Context, Spec, Table, Tools}
  alias IxpipeCore.Tools.{MacroInput, MacroOutput}
  import IxpipeCore.Duck, only: [ident: 1, literal: 1]

  defstruct [
    :path,
    :name,
    :spec,
    type: "standard",
    inputs: [],
    outputs: [],
    params: [],
    iterate: nil
  ]

  @type t :: %__MODULE__{
          path: String.t(),
          name: String.t(),
          spec: Spec.t(),
          type: String.t(),
          inputs: [{String.t(), String.t()}],
          outputs: [{String.t(), String.t()}],
          params: [IxpipeCore.Tool.field()],
          iterate: %{String.t() => term()} | nil
        }

  @types %{
    "string" => :string,
    "integer" => :integer,
    "bool" => :bool,
    "choice" => :choice,
    "list" => :list,
    "expr" => :expr,
    "path" => :path
  }
  @reserved ~w(path max_iterations)
  @ref ~r/\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}/
  @whole ~r/^\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}$/
  @max_iterations 100

  @doc "Whether `spec` is a macro: it has a `macro:` header or macro ports."
  @spec macro?(Spec.t()) :: boolean()
  def macro?(%Spec{macro: header, nodes: nodes}),
    do: header != nil or Enum.any?(nodes, &(&1.tool in [MacroInput, MacroOutput]))

  @doc "Whether the workflow file at `path` is a macro, read without loading what it uses."
  @spec file?(String.t()) :: boolean()
  def file?(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = doc} ->
        Map.has_key?(doc, "macro") or
          Enum.any?(
            List.wrap(doc["nodes"]),
            &(is_map(&1) and &1["tool"] in ~w(macro_input macro_output))
          )

      _ ->
        false
    end
  end

  @doc """
  Loads the macro of every macro node in `spec` into `node.macro`, each
  `path` relative to `dir`, or `{:error, reason}`. `within` lists the files
  being loaded around it, the innermost first, to reject cycles.
  """
  @spec attach(Spec.t(), String.t(), [String.t()]) :: Spec.t()
  def attach(%Spec{} = spec, dir, within \\ []) do
    nodes =
      Enum.map(spec.nodes, fn
        %{tool: Tools.Macro, config: %{"path" => path}} = node
        when is_binary(path) and path != "" ->
          macro =
            case load(Path.expand(path, dir), within) do
              {:ok, macro} -> macro
              {:error, {:not_found, _}} -> {:error, {:not_found, path}}
              error -> error
            end

          %{node | macro: macro}

        %{tool: Tools.Macro} = node ->
          %{node | macro: nil}

        node ->
          node
      end)

    %{spec | nodes: nodes}
  end

  @doc "Loads the macro at `path` (see `attach/3` for `within`)."
  @spec load(String.t(), [String.t()]) :: {:ok, t()} | {:error, term()}
  def load(path, within \\ []) do
    path = Path.expand(path)

    cond do
      path in within ->
        {:error, {:cycle, [path | within] |> Enum.reverse() |> Enum.drop_while(&(&1 != path))}}

      not File.regular?(path) ->
        {:error, {:not_found, path}}

      true ->
        with {:ok, draft} <- wrap(Spec.decode(File.read!(path), path: path, within: within), path),
             {:ok, macro} <- declare(draft, path),
             {:ok, spec} <- wrap(Spec.validate(draft), path) do
          {:ok, %{macro | spec: spec}}
        end
    end
  end

  # A cycle further in is the whole story; anything else names its file.
  defp wrap({:error, {:macro, _id, {:cycle, _} = cycle}}, _path), do: {:error, cycle}
  defp wrap({:error, reason}, path), do: {:error, {:invalid, path, reason}}
  defp wrap(ok, _path), do: ok

  @doc "A one-line description of a macro loading error."
  @spec format_error(term()) :: String.t()
  def format_error({:cycle, paths}),
    do: "macro cycle: " <> Enum.map_join(paths, " -> ", &Path.basename/1)

  def format_error({:not_found, path}), do: "no macro at #{path}"

  def format_error({:invalid, path, reason}),
    do: "#{Path.basename(path)}: #{Spec.format_error(reason)}"

  def format_error({:bad_macro, path, message}), do: "#{Path.basename(path)}: #{message}"

  @doc "The node's input ports: the macro's, then `control` for a batch macro."
  @spec inputs(t()) :: [String.t()]
  def inputs(%__MODULE__{} = macro),
    do: names(macro.inputs) ++ if(macro.type == "batch", do: ["control"], else: [])

  @doc "The node's outputs: the macro's, then `iterations` for an iterative macro."
  @spec outputs(t()) :: [String.t()]
  def outputs(%__MODULE__{} = macro),
    do: names(macro.outputs) ++ if(macro.type == "iterative", do: ["iterations"], else: [])

  @doc "The node's settings after `path`: the parameters, and an iterative macro's maximum."
  @spec fields(t()) :: [IxpipeCore.Tool.field()]
  def fields(%__MODULE__{type: "iterative"} = macro),
    do:
      macro.params ++
        [
          %{
            key: "max_iterations",
            label: "Maximum iterations",
            type: :integer,
            optional: true,
            default: macro.iterate["max"],
            hint: "Stops after this many iterations"
          }
        ]

  def fields(%__MODULE__{} = macro), do: macro.params

  defp names(ports), do: Enum.map(ports, &elem(&1, 0))

  @doc """
  The parameters a workflow's `macro:` header declares, as fields; `[]`
  for a workflow without any.
  """
  @spec params(Spec.t()) :: {:ok, [IxpipeCore.Tool.field()]} | {:error, String.t()}
  def params(%Spec{macro: header}), do: parse_params((header || %{})["parameters"] || [])

  @doc """
  Substitutes `values` (by parameter name, over the defaults) into a macro
  workflow run on its own. Other workflows come back unchanged.
  """
  @spec bind(Spec.t(), %{String.t() => term()}) :: Spec.t()
  def bind(%Spec{} = spec, values) do
    case params(spec) do
      {:ok, []} ->
        spec

      {:ok, params} ->
        defaults = for p <- params, Map.has_key?(p, :default), into: %{}, do: {p.key, p.default}
        values = Map.merge(defaults, values)
        %{spec | nodes: Enum.map(spec.nodes, &%{&1 | config: substitute(&1, values)})}

      {:error, _} ->
        spec
    end
  end

  ## Declaration

  defp declare(%Spec{} = spec, path) do
    header = spec.macro || %{}
    bad = fn message -> {:error, {:bad_macro, path, message}} end
    inputs = for n <- spec.nodes, n.tool == MacroInput, do: {port(n), n.id}
    outputs = for n <- spec.nodes, n.tool == MacroOutput, do: {port(n), n.id}
    type = header["type"] || "standard"

    with :ok <-
           check(
             type in ~w(standard batch iterative),
             "type must be standard, batch or iterative"
           ),
         {:ok, params} <- parse_params(header["parameters"] || []),
         :ok <- check(outputs != [], "add a Macro output, the macro's result"),
         :ok <- check(unique?(inputs) and unique?(outputs), "two macro ports share a name"),
         :ok <-
           check(
             type != "batch" or "control" not in names(inputs),
             "a batch macro's input can't be called control"
           ),
         {:ok, iterate} <- iterate(type, header["iterate"], inputs, outputs),
         :ok <- known_params(spec, params) do
      {:ok,
       %__MODULE__{
         path: path,
         name: spec.name || Path.rootname(Path.basename(path)),
         type: type,
         inputs: inputs,
         outputs: outputs,
         params: params,
         iterate: iterate
       }}
    else
      {:error, message} when is_binary(message) -> bad.(message)
    end
  end

  defp port(node), do: to_string(node.config["name"] || node.id)
  defp unique?(ports), do: names(ports) == Enum.uniq(names(ports))
  defp check(true, _message), do: :ok
  defp check(false, message), do: {:error, message}

  defp iterate("iterative", %{} = it, inputs, outputs) do
    max = it["max"] || @max_iterations

    cond do
      it["input"] not in names(inputs) -> {:error, "iterate's input must name a Macro input"}
      it["output"] not in names(outputs) -> {:error, "iterate's output must name a Macro output"}
      not (is_integer(max) and max > 0) -> {:error, "iterate's max must be a whole number over 0"}
      true -> {:ok, Map.put(it, "max", max)}
    end
  end

  defp iterate("iterative", _, _, _),
    do: {:error, "an iterative macro needs iterate: {input: …, output: …}"}

  defp iterate(_type, _iterate, _inputs, _outputs), do: {:ok, nil}

  defp parse_params(raw) when is_list(raw) do
    Enum.reduce_while(raw, {:ok, []}, fn param, {:ok, acc} ->
      case param(param) do
        {:ok, field} ->
          if Enum.any?(acc, &(&1.key == field.key)),
            do: {:halt, {:error, "two parameters are called #{field.key}"}},
            else: {:cont, {:ok, [field | acc]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, Enum.reverse(fields)}
      error -> error
    end
  end

  defp parse_params(_), do: {:error, "parameters must be a list"}

  defp param(%{"name" => name} = p) do
    name = to_string(name)
    type = @types[p["type"] || "string"]

    cond do
      not Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, name) ->
        {:error, "parameter #{inspect(name)} needs a name of letters, digits and _"}

      name in @reserved ->
        {:error, "a parameter can't be called #{name}"}

      type == nil ->
        {:error, "parameter #{name} has an unknown type #{inspect(p["type"])}"}

      type == :choice and not is_list(p["options"]) ->
        {:error, "parameter #{name} is a choice, so it needs options"}

      true ->
        field =
          %{key: name, label: to_string(p["label"] || humanize(name)), type: type}
          |> put(:options, p["options"] && Enum.map(p["options"], &to_string/1))
          |> put(:hint, p["hint"])

        field =
          if Map.has_key?(p, "default"),
            do: Map.merge(field, %{default: p["default"], optional: true}),
            else: field

        {:ok, field}
    end
  end

  defp param(_), do: {:error, "every parameter needs a name"}

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp humanize(name), do: name |> String.replace("_", " ") |> String.capitalize()

  defp known_params(spec, params) do
    keys = Enum.map(params, & &1.key)

    Enum.find_value(spec.nodes, :ok, fn node ->
      unknown = node.config |> refs() |> Enum.find(&(&1 not in keys))
      if unknown, do: {:error, "#{node.id} uses an unknown parameter #{unknown}"}
    end)
  end

  defp refs(value) when is_binary(value),
    do: for([_, name] <- Regex.scan(@ref, value), do: name)

  defp refs(value) when is_list(value), do: Enum.flat_map(value, &refs/1)
  defp refs(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&refs/1)
  defp refs(_), do: []

  ## Substitution

  # Each setting of `node` with `values` in place of `{{name}}`: SQL
  # literals in SQL settings, text (or the typed value) elsewhere.
  defp substitute(node, values) do
    types = Map.new(Tools.fields(node), &{&1.key, &1.type})

    Map.new(node.config, fn {key, value} ->
      mode = if types[key] in [:expr, :formulas], do: :sql, else: :text
      {key, subst(value, values, mode)}
    end)
  end

  defp subst(value, values, mode) when is_binary(value) do
    with :text <- mode,
         [_, name] <- Regex.run(@whole, value),
         true <- Map.has_key?(values, name) do
      values[name]
    else
      _ ->
        Regex.replace(@ref, value, fn whole, name ->
          if Map.has_key?(values, name), do: render(values[name], mode), else: whole
        end)
    end
  end

  defp subst(value, values, mode) when is_list(value),
    do: Enum.map(value, &subst(&1, values, mode))

  defp subst(value, values, mode) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {k, v} -> {k, subst(v, values, mode)} end)

  defp subst(value, _values, _mode), do: value

  defp render(nil, :sql), do: "NULL"
  defp render(true, :sql), do: "TRUE"
  defp render(false, :sql), do: "FALSE"
  defp render(n, :sql) when is_number(n), do: to_string(n)
  defp render(list, :sql) when is_list(list), do: Enum.map_join(list, ", ", &render(&1, :sql))
  defp render(value, :sql), do: literal(to_string(value))
  defp render(nil, :text), do: ""
  defp render(list, :text) when is_list(list), do: Enum.map_join(list, ", ", &to_string/1)
  defp render(value, :text), do: to_string(value)

  ## Running

  @doc false
  # The macro tool's run: once, per batch, or per iteration.
  def run(%__MODULE__{} = macro, inputs, config, ctx) do
    values =
      for p <- macro.params, into: %{}, do: {p.key, Map.get(config, p.key, p[:default])}

    case macro.type do
      "standard" -> standard(macro, values, inputs, config, ctx)
      "batch" -> batch(macro, values, inputs, config, ctx)
      "iterative" -> iterative(macro, values, inputs, config, ctx)
    end
  end

  defp standard(macro, values, inputs, config, ctx) do
    with {:ok, outs} <- once(macro, values, inputs, config, ctx, "#{ctx.id}/") do
      emit(ctx, Map.new(outs, fn {name, table} -> {name, [table]} end), single?(macro))
    end
  end

  defp batch(macro, values, inputs, config, ctx) do
    control = inputs["control"]
    keys = for p <- macro.params, p.key in Table.columns(control), do: p.key
    batches = batches(control, keys)
    inputs = Map.delete(inputs, "control")

    # Without a batch, one run with the node's own values gives the outputs'
    # columns, and none of its rows.
    runs = if batches == [], do: [%{}], else: batches

    runs
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}}, fn {row, i}, {:ok, acc} ->
      values = Map.merge(values, coerce(row, macro.params))

      case once(macro, values, inputs, config, ctx, "#{ctx.id}/#{i}/") do
        {:ok, outs} ->
          {:cont,
           {:ok,
            Map.merge(acc, Map.new(outs, &{elem(&1, 0), [elem(&1, 1)]}), fn _, a, b -> a ++ b end)}}

        failed ->
          {:halt, failed}
      end
    end)
    |> case do
      {:ok, outs} -> emit(ctx, outs, single?(macro), batches == [])
      failed -> failed
    end
  end

  # One batch per distinct combination of the parameter columns, in the
  # order they first appear.
  defp batches(control, []), do: if(Table.count(control) > 0, do: [%{}], else: [])

  defp batches(control, keys) do
    columns = Enum.map_join(keys, ", ", &ident/1)

    %{rows: rows} =
      Table.query!(
        control.db,
        "SELECT #{columns} FROM #{Table.ref(control)} GROUP BY #{columns} ORDER BY min(rowid)"
      )

    Enum.map(rows, &Map.new(Enum.zip(keys, &1)))
  end

  # Control values read as text become the parameter's type.
  defp coerce(row, params) do
    Map.new(row, fn {key, value} ->
      field = Enum.find(params, &(&1.key == key))

      case value do
        text when is_binary(text) and field.type in [:integer, :bool, :list] ->
          case Config.parse(field, text) do
            {:ok, typed} -> {key, typed}
            _ -> {key, text}
          end

        _ ->
          {key, value}
      end
    end)
  end

  defp iterative(macro, values, inputs, config, ctx) do
    %{"input" => input, "output" => output} = macro.iterate
    max = config["max_iterations"] || macro.iterate["max"]
    iterate(macro, values, inputs, config, ctx, {input, output, max}, 1, %{})
  end

  defp iterate(macro, values, inputs, config, ctx, {input, output, max} = it, i, acc) do
    with {:ok, outs} <- once(macro, values, inputs, config, ctx, "#{ctx.id}/#{i}/") do
      again = outs[output]
      acc = Map.merge(acc, Map.new(outs, &{elem(&1, 0), [elem(&1, 1)]}), fn _, a, b -> a ++ b end)

      if Table.count(again) == 0 or i >= max do
        ctx
        |> emit(Map.put(acc, output, [again]), false)
        |> Map.put("iterations", Context.table(ctx, "iterations", iterations: [i]))
      else
        iterate(macro, values, Map.put(inputs, input, again), config, ctx, it, i + 1, acc)
      end
    end
  end

  # Runs the inner workflow once, its tables under `prefix`: the macro's
  # outputs by port name, or the inner tool that failed.
  defp once(macro, values, inputs, config, ctx, prefix) do
    spec = instantiate(macro, values, inputs, config)
    results = IxpipeCore.execute(spec, ctx.db, prefix)

    case Enum.find(Map.values(results), &match?({:failed, _, _}, &1)) do
      nil -> {:ok, Map.new(macro.outputs, fn {name, id} -> {name, results[id]} end)}
      failed -> failed
    end
  end

  defp instantiate(macro, values, inputs, config) do
    dir = Path.dirname(macro.path)
    bound = Map.new(macro.inputs, fn {name, id} -> {id, inputs[name]} end)

    nodes =
      for node <- macro.spec.nodes do
        config =
          node
          |> substitute(values)
          |> resolve(dir)
          |> put_new("_home", config["_home"])
          |> put("_bound", bound[node.id])

        %{node | config: config}
      end

    %{macro.spec | nodes: nodes}
  end

  defp put_new(config, _key, nil), do: config
  defp put_new(config, key, value), do: Map.put_new(config, key, value)

  # Relative paths inside a macro are relative to the macro's file.
  defp resolve(%{"path" => path} = config, dir) when is_binary(path),
    do: %{config | "path" => Path.expand(path, dir)}

  defp resolve(config, _dir), do: config

  # The node's tables from each output's tables (several are unioned by
  # name): its only table, or one per output.
  defp emit(ctx, outs, single?, empty? \\ false) do
    limit = if empty?, do: " LIMIT 0", else: ""

    tables =
      for {name, tables} <- outs, into: %{} do
        select = Enum.map_join(tables, " UNION ALL BY NAME ", &"SELECT * FROM #{Table.ref(&1)}")
        {name, fn output -> Context.sql(ctx, output, "SELECT * FROM (#{select})#{limit}") end}
      end

    case Map.keys(tables) do
      [name] when single? -> tables[name].(nil)
      names -> Map.new(names, &{&1, tables[&1].(&1)})
    end
  end

  defp single?(macro), do: length(outputs(macro)) == 1
end
