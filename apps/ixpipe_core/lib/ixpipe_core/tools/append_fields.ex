defmodule IxpipeCore.Tools.AppendFields do
  @moduledoc """
  Appends every row of `source` to every row of `target` (a cartesian
  join), for adding a few constants or a summary to each record. Rows come
  out in target order, then source order; a source column whose name the
  target has gets the prefix `Source_`.

  Config, optional: `limit` (default 16) and `too_many`, what happens when
  `source` has more rows than `limit`: `error` (default), `warn` (append
  them and log a warning) or `allow`.
  """
  @behaviour IxpipeCore.Tool

  require Logger
  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @impl true
  def inputs, do: ["target", "source"]

  @impl true
  def fields,
    do: [
      %{
        key: "limit",
        label: "Source row limit",
        type: :integer,
        hint: "Most source rows to append",
        default: 16,
        optional: true
      },
      %{
        key: "too_many",
        label: "Over the limit",
        type: :choice,
        options: ~w(error warn allow),
        default: "error",
        optional: true
      }
    ]

  @impl true
  def run(%{"target" => target, "source" => source}, config, ctx) do
    limit = config["limit"] || 16
    rows = Table.count(source)

    if rows > limit do
      message =
        "The source has #{rows} rows, over the limit of #{limit}. " <>
          "Raise the limit or set Over the limit to allow."

      case config["too_many"] || "error" do
        "error" -> raise message
        "warn" -> Logger.warning("#{ctx.id}: #{message}")
        _ -> :ok
      end
    end

    target_columns = Table.columns(target)

    sources =
      for c <- Table.columns(source) do
        if c in target_columns,
          do: "s.#{ident(c)} AS #{ident("Source_" <> c)}",
          else: "s.#{ident(c)}"
      end

    Context.sql(ctx, """
    SELECT t.* EXCLUDE (__t), #{Enum.join(sources, ", ")}
    FROM (SELECT *, rowid AS __t FROM #{Table.ref(target)}) t
    CROSS JOIN (SELECT *, rowid AS __s FROM #{Table.ref(source)}) s
    ORDER BY t.__t, s.__s
    """)
  end
end
