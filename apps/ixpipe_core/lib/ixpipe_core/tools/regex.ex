defmodule IxpipeCore.Tools.Regex do
  @moduledoc """
  Regular expressions on `column` (RE2 syntax, as DuckDB's), by `mode`:

    * `parse` (default): each capture group becomes a column, named after
      the group, or `<column>_1`, `_2`, ... when unnamed; empty without a match.
    * `match`: adds `<column>_matched`, true where the whole value matches.
    * `replace`: replaces every match with `replacement` (`$1` or `${name}` refers to a group).
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1, literal: 1]

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{key: "column", label: "Column", type: :string, hint: "The text column to search"},
      %{
        key: "pattern",
        label: "Pattern",
        type: :string,
        hint: "e.g. (?<user>[^@]+)@(?<domain>.+)"
      },
      %{
        key: "mode",
        label: "Mode",
        type: :choice,
        options: ~w(parse match replace),
        default: "parse",
        optional: true
      },
      %{
        key: "replacement",
        label: "Replace with",
        type: :string,
        hint: "For replace; $1 is the first group",
        optional: true
      }
    ]

  @impl true
  def run(%{"in" => t}, %{"column" => column, "pattern" => pattern} = config, ctx) do
    # RE2 spells a named group (?P<name>…); accept (?<name>…) too.
    pattern = String.replace(pattern, ~r/\(\?<(?=[A-Za-z_])/, "(?P<")
    check!(t.db, pattern)
    c = ident(column)
    p = literal(pattern)
    from = Table.ref(t)

    case config["mode"] do
      "match" ->
        Context.sql(
          ctx,
          "SELECT *, coalesce(regexp_full_match(#{c}, #{p}), false) AS #{ident("#{column}_matched")} FROM #{from}"
        )

      "replace" ->
        replacement = rewrite(config["replacement"] || "", groups(pattern))

        Context.sql(
          ctx,
          "SELECT * REPLACE (regexp_replace(#{c}, #{p}, #{literal(replacement)}, 'g') AS #{c}) FROM #{from}"
        )

      _ ->
        parse(t, column, pattern, ctx)
    end
  end

  # DuckDB only reports a bad pattern when a query uses it.
  defp check!(db, pattern) do
    case IxpipeCore.Duck.query(db, "SELECT regexp_matches('', #{literal(pattern)})") do
      {:ok, _} -> :ok
      {:error, message} -> raise "Invalid pattern #{pattern}: #{message}"
    end
  end

  defp parse(t, column, pattern, ctx) do
    names =
      pattern
      |> groups()
      |> Enum.with_index(1)
      |> Enum.map(fn {name, i} -> name || "#{column}_#{i}" end)

    if names == [],
      do: Context.sql(ctx, "SELECT * FROM #{Table.ref(t)}"),
      else: extract(t, column, pattern, names, ctx)
  end

  defp extract(t, column, pattern, names, ctx) do
    c = ident(column)
    p = literal(pattern)
    labels = Enum.map_join(1..length(names)//1, ", ", &"'g#{&1}'")
    # A group named like an existing column replaces it.
    taken = Enum.filter(names, &(&1 in Table.columns(t)))
    keep = "* EXCLUDE (#{Enum.map_join(["__m" | taken], ", ", &ident/1)})"

    columns =
      for {name, i} <- Enum.with_index(names, 1),
          do: "__m.g#{i} AS #{ident(name)}"

    # Without a match every group is NULL.
    Context.sql(ctx, """
    SELECT #{Enum.join([keep | columns], ", ")} FROM (
      SELECT *, CASE WHEN regexp_matches(#{c}, #{p}) THEN regexp_extract(#{c}, #{p}, [#{labels}]) END AS __m
      FROM #{Table.ref(t)}
    )
    """)
  end

  @doc false
  # The capture groups in order: a name, or nil when unnamed.
  def groups(pattern), do: groups(pattern, [])

  defp groups(<<"\\", _::utf8, rest::binary>>, acc), do: groups(rest, acc)
  defp groups(<<"[", rest::binary>>, acc), do: groups(class(rest), acc)

  defp groups(<<"(?P<", rest::binary>>, acc) do
    [name, rest] = String.split(rest, ">", parts: 2)
    groups(rest, [name | acc])
  end

  defp groups(<<"(?", rest::binary>>, acc), do: groups(rest, acc)
  defp groups(<<"(", rest::binary>>, acc), do: groups(rest, [nil | acc])
  defp groups(<<_::utf8, rest::binary>>, acc), do: groups(rest, acc)
  defp groups(_, acc), do: Enum.reverse(acc)

  # Skips a character class; a ] first (after any ^) is literal.
  defp class(<<"^", rest::binary>>), do: class_body(skip_bracket(rest))
  defp class(rest), do: class_body(skip_bracket(rest))

  defp skip_bracket(<<"]", rest::binary>>), do: rest
  defp skip_bracket(rest), do: rest

  defp class_body(<<"\\", _::utf8, rest::binary>>), do: class_body(rest)

  defp class_body(<<"[:", rest::binary>>),
    do: rest |> String.split(":]", parts: 2) |> List.last() |> class_body()

  defp class_body(<<"]", rest::binary>>), do: rest
  defp class_body(<<_::utf8, rest::binary>>), do: class_body(rest)
  defp class_body(_), do: ""

  # $1, ${1}, $name and ${name} become RE2's \1; $$ is a dollar and a
  # backslash is literal.
  defp rewrite(replacement, names) do
    index =
      names
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {n, i} -> if n, do: [{n, i}], else: [] end)
      |> Map.new()

    Regex.replace(~r/\$\$|\$\{(\w+)\}|\$(\w+)|\\/, replacement, fn
      "$$", _, _ -> "$"
      "\\", _, _ -> "\\\\"
      _, braced, bare -> group(braced <> bare, index)
    end)
  end

  defp group(ref, index) do
    case Integer.parse(ref) do
      {i, ""} -> "\\#{i}"
      _ -> if i = index[ref], do: "\\#{i}", else: ""
    end
  end
end
