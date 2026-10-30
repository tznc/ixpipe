defmodule IxpipeCore.Python do
  @moduledoc """
  Sandboxed Python: RustPython embedded in a Rust NIF (`native/ixpipe_python`),
  so no system Python is needed, on desktop or Android.

  The script sees `inputs`, a dict of input name to rows (lists of dicts),
  and sets `output` to a list of dicts or a dict of column lists. `print`
  goes to `stdout`. It can't open files, reach the network or start
  processes (the interpreter is built without them), imports only
  pure-Python modules on an allow-list, and stops past its CPU time
  (`:timeout`, ms; wall time is capped at twice that), its memory
  (`:memory`, bytes) or when its `:job` is cancelled (`cancel/1`).
  """
  use Rustler, otp_app: :ixpipe_core, crate: "ixpipe_python", mode: :release

  @type table :: {[String.t()], [[term()]]}
  @type error :: %{
          kind:
            :exception | :timeout | :memory | :cancelled | :no_output | :bad_output | :crashed,
          message: String.t(),
          traceback: String.t(),
          stdout: String.t()
        }

  @timeout 30_000
  @memory 256 * 1024 * 1024
  @recursion 1_000
  @int64 -0x8000000000000000..0x7FFFFFFFFFFFFFFF

  @doc """
  Runs `code` with `inputs` (name to `{columns, rows}`). Replies the table
  it set as `output`, with its stdout, or why it failed.
  """
  @spec run(String.t(), %{String.t() => table()}, keyword()) ::
          {:ok, %{columns: [String.t()], rows: [[term()]], stdout: String.t()}}
          | {:error, error()}
  def run(code, inputs, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    memory = Keyword.get(opts, :memory, @memory)
    job = Keyword.get_lazy(opts, :job, &job/0)

    inputs =
      for {name, {columns, rows}} <- inputs,
          do: {name, columns, Enum.map(rows, &Enum.map(&1, fn v -> encode(v) end))}

    case run_nif(job, code, inputs, {timeout, 2 * timeout + 1_000, memory, @recursion}) do
      {:ok, {columns, rows}, stdout} ->
        rows = Enum.map(rows, &Enum.map(&1, fn v -> decode(v) end))
        {:ok, %{columns: columns, rows: rows, stdout: stdout}}

      {:error, kind, {name, message, traceback}, stdout} ->
        {:error,
         %{
           kind: kind,
           message: message(kind, name, message, traceback, timeout, memory),
           traceback: traceback,
           stdout: stdout
         }}
    end
  end

  @doc "A handle to cancel a run with: pass it as `run/3`'s `:job`."
  @spec job() :: reference()
  def job, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Stops the run holding `job` at its next instruction."
  @spec cancel(reference()) :: :ok
  def cancel(_job), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def run_nif(_job, _code, _inputs, _limits), do: :erlang.nif_error(:nif_not_loaded)

  defp message(:exception, name, message, traceback, _timeout, _memory) do
    where =
      case Regex.scan(~r/File "script\.py", line (\d+)/, traceback) do
        [] -> ""
        lines -> " on line " <> (lines |> List.last() |> List.last())
      end

    "Python raised #{name}#{where}: #{String.trim_trailing(message, ".")}."
  end

  defp message(:timeout, _, _, _, timeout, _),
    do:
      "The script ran past its time limit of #{seconds(timeout)}. Make it faster or raise the limit."

  defp message(:memory, _, _, _, _, memory),
    do:
      "The script used more than its memory limit of #{div(memory, 1024 * 1024)} MB. " <>
        "Use less data or raise the limit."

  defp message(:cancelled, _, _, _, _, _), do: "The run was cancelled."

  defp message(:no_output, _, _, _, _, _),
    do: "The script didn't set output. Assign a list of dicts or a dict of columns to output."

  defp message(:bad_output, _, what, _, _, _),
    do: "The script's #{what}. Assign a list of dicts or a dict of columns to output."

  defp message(:crashed, _, message, _, _, _), do: message

  defp seconds(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)} s"
  defp seconds(ms), do: "#{ms / 1000} s"

  defp encode(%Date{year: y, month: m, day: d}), do: {:date, y, m, d}

  defp encode(%NaiveDateTime{} = t),
    do: {:datetime, t.year, t.month, t.day, t.hour, t.minute, t.second, elem(t.microsecond, 0)}

  defp encode(%DateTime{} = t), do: encode(DateTime.to_naive(t))
  defp encode(%Time{} = t), do: {:time, t.hour, t.minute, t.second, elem(t.microsecond, 0)}
  defp encode(%Decimal{} = d), do: Decimal.to_float(d)
  defp encode(v) when is_integer(v) and v not in @int64, do: Integer.to_string(v)
  defp encode(v) when is_nil(v) or is_boolean(v) or is_number(v), do: v

  defp encode(v) when is_binary(v),
    do: if(String.valid?(v), do: v, else: Base.encode64(v))

  defp encode(v) when is_map(v) or is_list(v), do: Jason.encode!(v)
  defp encode(v), do: to_string(v)

  defp decode({:date, y, m, d}), do: Date.new!(y, m, d)

  defp decode({:datetime, {y, mo, d}, {h, mi, s, us}}),
    do: NaiveDateTime.new!(y, mo, d, h, mi, s, {us, 6})

  defp decode({:time, h, m, s, us}), do: Time.new!(h, m, s, {us, 6})
  defp decode(v), do: v
end
