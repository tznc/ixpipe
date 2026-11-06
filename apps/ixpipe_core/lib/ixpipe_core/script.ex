defmodule IxpipeCore.Script do
  @moduledoc """
  Code in a language installed on this computer (Python, JavaScript on
  Node, Ruby, PHP), run through [portals](https://hex.pm/packages/portals)
  in its own OS process: the full-power counterpart of the sandboxed
  `IxpipeCore.Python`, with the user's own packages and no limits beyond a
  time limit. Desktop only: phones can't start other programs.

  Data goes through files in a run directory: JSON lines (rows a script
  reads with its standard library) or Parquet (for pandas, Arrow and the
  like). Each run starts a fresh worker and stops it after, so a script
  past its time limit is killed.
  """

  @languages [
    {"python", "Python", "python3", "a Python 3 executable"},
    {"javascript", "JavaScript", "node", "a Node.js executable"},
    {"ruby", "Ruby", "ruby", "a Ruby executable"},
    {"php", "PHP", "php", "a PHP 8 executable"}
  ]
  # Languages people ask for that portals doesn't run.
  @unsupported %{"r" => "R", "java" => "Java", "go" => "Go"}
  @todo_output "Assign a list of rows or a table of columns to output."

  @type language :: String.t()
  @type failure :: %{
          kind: :exception | :timeout | :no_output | :bad_output | :runtime,
          message: String.t(),
          traceback: String.t(),
          stdout: String.t(),
          stderr: String.t()
        }

  @doc "The languages Script runs."
  @spec languages() :: [language()]
  def languages, do: for({language, _, _, _} <- @languages, do: language)

  @doc "A language's name as people write it (\"JavaScript\")."
  @spec label(language()) :: String.t()
  def label(language) do
    case List.keyfind(@languages, language, 0) do
      {_, label, _, _} -> label
      nil -> Map.get_lazy(@unsupported, language, fn -> String.capitalize(language) end)
    end
  end

  @doc "Every language with its runtime, as `runtime/2` finds it."
  @spec runtimes() :: [
          %{
            language: language(),
            label: String.t(),
            found: {:ok, String.t()} | {:error, String.t()}
          }
        ]
  def runtimes,
    do:
      for(
        {language, label, _, _} <- @languages,
        do: %{language: language, label: label, found: runtime(language)}
      )

  @doc "Whether this device can run Script at all: not on Android."
  @spec supported?() :: boolean()
  def supported?, do: System.get_env("ANDROID_ROOT") == nil

  @doc "Why Script can't run on a phone, and what to use instead."
  @spec desktop_only() :: String.t()
  def desktop_only,
    do:
      "Script runs on desktop only: phones can't start other programs. " <>
        "Use the Python tool, which runs anywhere."

  @doc """
  The executable that runs `language`: `interpreter` (a path, or a name on
  PATH) when given, else the language's usual command. When there is none,
  says what happened and what to do.
  """
  @spec runtime(language(), String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def runtime(language, interpreter \\ nil) do
    case List.keyfind(@languages, language, 0) do
      nil ->
        {:error,
         "#{label(language)} isn't supported by Script: it runs " <>
           "#{Enum.map_join(@languages, ", ", &elem(&1, 1))}. Choose one of those."}

      {_, label, command, what} ->
        cond do
          not supported?() ->
            {:error, desktop_only()}

          interpreter in [nil, ""] ->
            case System.find_executable(command) do
              nil ->
                {:error,
                 "#{label} isn't installed: there's no #{command} on PATH. Install it, or set Interpreter to #{what}."}

              path ->
                {:ok, path}
            end

          true ->
            path = Path.expand(interpreter)

            cond do
              File.regular?(path) ->
                {:ok, path}

              found = !String.contains?(interpreter, "/") && System.find_executable(interpreter) ->
                {:ok, found}

              true ->
                {:error,
                 "#{label} isn't installed at #{interpreter}. Install it, or set Interpreter to #{what}."}
            end
        end
    end
  end

  @doc """
  Runs `code` in `language` with `inputs` (name to a file: JSON lines, or
  Parquet with `format: "parquet"`), the script writing its table to
  `output`. Replies what it wrote (`%{"format" => "jsonl" | "parquet", ...}`)
  with its stdout and stderr, or why it failed.

  Options: `:interpreter`, `:format` (`"jsonl"` or `"parquet"`), `:timeout` (ms).
  """
  @spec run(language(), String.t(), %{String.t() => Path.t()}, Path.t(), keyword()) ::
          {:ok, %{written: map(), stdout: String.t(), stderr: String.t()}} | {:error, failure()}
  def run(language, code, inputs, output, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    format = Keyword.get(opts, :format, "jsonl")

    with {:ok, executable} <- runtime(language, opts[:interpreter]) |> runtime_error() do
      # The worker is linked to the task, not the caller: a crashed worker
      # fails this node, not the run.
      task =
        Task.Supervisor.async_nolink(IxpipeCore.TaskSupervisor, fn ->
          call(language, executable, [code, inputs, output, format], timeout)
        end)

      case Task.yield(task, timeout + 15_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, reply} ->
          reply

        _ ->
          {:error,
           failure(:runtime, "The #{label(language)} worker stopped answering. Run again.")}
      end
    end
  end

  defp runtime_error({:error, message}), do: {:error, failure(:runtime, message)}
  defp runtime_error(ok), do: ok

  defp call(language, executable, args, timeout) do
    case Portals.start_worker(worker_opts(language, executable)) do
      {:ok, worker} ->
        try do
          reply(
            language,
            Portals.call(worker, "ixpipe_runner", "run", args, timeout: timeout),
            timeout
          )
        after
          # Force-kills the process if it doesn't stop at once (a busy loop).
          Portals.stop_worker(worker, 200)
        end

      {:error, reason} ->
        {:error,
         failure(
           :runtime,
           "#{label(language)} didn't start (#{inspect(reason)}). Check that it runs from a terminal."
         )}
    end
  end

  defp reply(_language, {:ok, %{"error" => nil, "written" => written} = result}, _timeout) do
    cond do
      written["missing"] ->
        {:error, failure(:no_output, "The script didn't set output. #{@todo_output}", result)}

      bad = written["bad"] ->
        {:error, failure(:bad_output, "The script's #{bad}. #{@todo_output}", result)}

      true ->
        {:ok, %{written: written, stdout: result["stdout"], stderr: result["stderr"]}}
    end
  end

  defp reply(language, {:ok, %{"error" => error} = result}, _timeout) do
    where = if error["line"], do: " on line #{error["line"]}", else: ""
    message = String.trim_trailing(to_string(error["message"]), ".")

    {:error,
     %{
       failure(
         :exception,
         "#{label(language)} raised #{error["type"]}#{where}: #{message}.",
         result
       )
       | traceback: error["traceback"] || ""
     }}
  end

  defp reply(_language, {:error, %{kind: kind}}, timeout)
       when kind in [:timeout, :execution_timeout],
       do:
         {:error,
          failure(
            :timeout,
            "The script ran past its time limit of #{div(timeout, 1000)} s. Make it faster or raise the limit."
          )}

  defp reply(language, {:error, error}, _timeout),
    do: {:error, failure(:runtime, "#{label(language)} failed: #{error.message}. Run again.")}

  defp failure(kind, message, result \\ %{}),
    do: %{
      kind: kind,
      message: message,
      traceback: "",
      stdout: result["stdout"] || "",
      stderr: result["stderr"] || ""
    }

  defp worker_opts(language, executable) do
    dir = Application.app_dir(:ixpipe_core, "priv/script/#{language}")

    case language do
      "python" ->
        Portals.Python.worker_opts(script: Path.join(dir, "worker.py"), python: executable)

      "javascript" ->
        Portals.JavaScript.worker_opts(
          script: Path.join(dir, "worker.js"),
          executable: executable
        )

      "ruby" ->
        Portals.Ruby.worker_opts(script: Path.join(dir, "worker.rb"), ruby: executable)

      "php" ->
        Portals.PHP.worker_opts(script: Path.join(dir, "worker.php"), php: executable)
    end
    |> Keyword.put(:connect_timeout, 15_000)
  end
end
