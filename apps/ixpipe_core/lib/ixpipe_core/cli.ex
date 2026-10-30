defmodule IxpipeCore.CLI do
  @moduledoc """
  Headless runs, for scripts, CI and schedulers (cron, systemd timers):

      ixpipe run sales.yaml [--json] [--output-dir DIR] [--param NAME=VALUE ...]
      ixpipe validate sales.yaml

  Relative `path` settings resolve against the workflow's directory; with
  `--output-dir`, output tools' relative paths resolve against that instead.
  Macros (`IxpipeCore.Macro`) resolve against the folder of the file that
  uses them. `--param` sets a parameter of a macro workflow run on its own,
  typed as the parameter declares.

  `main/2` returns the exit code (0 ok, 1 the workflow failed, 2 usage) and
  never halts, so it is callable from `mix ixpipe.run` and the release's
  `bin/ixpipe-run`.
  """

  alias IxpipeCore.{Config, Macro, Spec, Tools}

  @usage """
  Usage:
    ixpipe run PATH [--json] [--output-dir DIR]   run a workflow
        [--param NAME=VALUE ...]                  set a macro workflow's parameters
    ixpipe validate PATH                          check a workflow without running it
    ixpipe help                                   show this help

  Exit codes: 0 succeeded, 1 the workflow failed, 2 bad usage.
  """

  @spec main([String.t()], IO.device()) :: non_neg_integer()
  def main(argv, io \\ :stdio) do
    case OptionParser.parse(argv, strict: [json: :boolean, output_dir: :string, param: :keep]) do
      {_opts, ["help"], []} ->
        IO.write(io, @usage)
        0

      {opts, [command, path], []} when command in ["run", "validate"] ->
        if File.regular?(path),
          do: command(command, path, opts, io),
          else: usage(io, "No workflow at #{path}.")

      {_opts, [], _} ->
        usage(io, nil)

      _ ->
        usage(io, "Unknown command: #{Enum.join(argv, " ")}")
    end
  end

  defp command("validate", path, _opts, io) do
    case load(path, nil) do
      {:ok, spec} ->
        IO.puts(io, "Valid: #{length(spec.nodes)} tools")
        0

      {:error, reason} ->
        IO.puts(io, Spec.format_error(reason))
        1
    end
  end

  defp command("run", path, opts, io) do
    started = System.monotonic_time(:millisecond)

    with {:ok, spec} <- load(path, opts[:output_dir]),
         {:ok, params} <- params(spec, Keyword.get_values(opts, :param), path) do
      result =
        with :ok <- make_output_dir(opts[:output_dir]),
             {:ok, results} <- IxpipeCore.run(spec, params: params) do
          {:ok, spec, results}
        end

      ms = System.monotonic_time(:millisecond) - started
      report(result, ms, opts[:json], io)
    else
      {:usage, message} -> usage(io, message)
      error -> report(error, System.monotonic_time(:millisecond) - started, opts[:json], io)
    end
  end

  # `--param name=value`, read with the parameter's field.
  defp params(spec, pairs, path) do
    fields =
      case Macro.params(spec),
        do: (
          {:ok, fields} -> fields
          _ -> []
        )

    Enum.reduce_while(pairs, {:ok, %{}}, fn pair, {:ok, acc} ->
      with [name, text] <- String.split(pair, "=", parts: 2),
           %{} = field <- Enum.find(fields, &(&1.key == name)),
           {:ok, value} <- Config.parse(field, text) do
        {:cont, {:ok, Map.put(acc, name, value)}}
      else
        [_] ->
          {:halt, {:usage, "Write --param as name=value."}}

        nil ->
          {:halt,
           {:usage, "#{Path.basename(path)} has no parameter #{hd(String.split(pair, "="))}."}}

        {:error, message} ->
          {:halt, {:usage, "#{hd(String.split(pair, "="))}: #{message}."}}
      end
    end)
  end

  defp load(path, output_dir) do
    with {:ok, spec} <- path |> File.read!() |> Spec.decode(path: path) do
      spec |> resolve_paths(Path.dirname(Path.expand(path)), output_dir) |> Spec.validate()
    end
  end

  defp make_output_dir(nil), do: :ok
  defp make_output_dir(dir), do: File.mkdir_p(dir)

  # Relative `path` settings resolve against the workflow's directory, or
  # for output tools against --output-dir when given.
  defp resolve_paths(spec, base, output_dir) do
    nodes =
      for node <- spec.nodes do
        case node.config do
          %{"path" => path} when is_binary(path) ->
            output? = String.starts_with?(Tools.name(node.tool), "output_")
            dir = if output? && output_dir, do: Path.expand(output_dir), else: base
            %{node | config: %{node.config | "path" => Path.expand(path, dir)}}

          _ ->
            node
        end
      end

    %{spec | nodes: nodes}
  end

  defp report({:ok, spec, results}, ms, json, io) do
    # A tool with one output reports its rows; one with several reports each
    # output's rows (results are keyed `node.output` for those).
    nodes =
      for node <- spec.nodes do
        base = %{"id" => node.id, "tool" => Tools.name(node.tool)}

        case Tools.outputs(node) do
          [_] ->
            Map.put(base, "rows", IxpipeCore.Table.count(results[node.id]))

          outputs ->
            counts = Map.new(outputs, &{&1, IxpipeCore.Table.count(results["#{node.id}.#{&1}"])})

            base
            |> Map.put("rows", nil)
            |> Map.put("outputs", counts)
            |> Map.put("order", outputs)
        end
      end

    if json do
      nodes = Enum.map(nodes, &Map.delete(&1, "order"))
      IO.puts(io, Jason.encode!(%{status: "ok", error: nil, ms: ms, nodes: nodes}))
    else
      id_width = nodes |> Enum.map(&String.length(&1["id"])) |> Enum.max(fn -> 0 end)
      tool_width = nodes |> Enum.map(&String.length(&1["tool"])) |> Enum.max(fn -> 0 end)

      for %{"id" => id, "tool" => tool} = node <- nodes do
        IO.puts(
          io,
          "#{String.pad_trailing(id, id_width)}  #{String.pad_trailing(tool, tool_width)}  #{counts(node)}"
        )
      end

      IO.puts(io, "Run succeeded in #{ms} ms")
    end

    0
  end

  defp report({:error, reason}, ms, json, io) do
    message =
      case reason do
        {:node_failed, id, message} -> "#{id} failed: #{message}"
        reason when is_atom(reason) -> "Could not create the output directory: #{reason}"
        reason -> Spec.format_error(reason)
      end

    if json,
      do: IO.puts(io, Jason.encode!(%{status: "error", error: message, ms: ms, nodes: []})),
      else: IO.puts(io, "Run failed: #{message}")

    1
  end

  defp usage(io, nil) do
    IO.write(io, @usage)
    2
  end

  defp usage(io, message) do
    IO.puts(io, message)
    usage(io, nil)
  end

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(n, noun), do: "#{n} #{noun}s"

  defp counts(%{"outputs" => counts, "order" => order}),
    do: Enum.map_join(order, ", ", &"#{&1} #{plural(counts[&1], "row")}")

  defp counts(%{"rows" => rows}), do: plural(rows, "row")
end
