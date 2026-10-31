defmodule IxpipeCore.Errors do
  @moduledoc """
  Turns a tool's raw error (mostly DuckDB's, such as `Binder Error:
  Referenced column "x" not found in FROM clause!`) into the design
  language's "what happened. what to do." The raw text stays with the
  message as its detail.
  """

  @generic "Check the tool's settings and run again."

  @doc "The error `raw`, as what happened and what to do."
  @spec humanize(String.t()) :: String.t()
  def humanize(raw) do
    first = raw |> String.split("\n", trim: true) |> List.first("") |> String.trim()

    cond do
      m = Regex.run(~r/Referenced column "([^"]+)" not found/, raw) ->
        candidates =
          case Regex.run(~r/Candidate bindings: (.+)/, raw) do
            [_, names] -> ", or use one of: " <> clean_candidates(names)
            nil -> ""
          end

        ~s(Column "#{Enum.at(m, 1)}" isn't in the input. Check the spelling#{candidates}.)

      m = Regex.run(~r/Function with name "?([^"\s]+?)"? does not exist/, raw) ->
        hint =
          case Regex.run(~r/Did you mean "([^"(]+)/, raw) do
            [_, name] -> "Did you mean #{name}? "
            nil -> ""
          end

        "There's no function named #{Enum.at(m, 1)}. #{hint}Check the name against DuckDB's functions."

      m = Regex.run(~r/syntax error at or near "([^"]*)"/, raw) ->
        ~s(The expression can't be read near "#{Enum.at(m, 1)}". Check its brackets, quotes and operators.)

      String.contains?(raw, "syntax error at end of input") ->
        "The expression ends too soon. Check it's complete."

      m = Regex.run(~r/Could not convert string '([^']*)' to (\w+)/, raw) ->
        "The value '#{Enum.at(m, 1)}' can't be converted to #{type(Enum.at(m, 2))}. " <>
          "Clean the column with Data cleansing, or use TRY_CAST to make such values NULL."

      m = Regex.run(~r/No files found that match the pattern "([^"]+)"/, raw) ->
        "The file #{Enum.at(m, 1)} doesn't exist. Choose a file that does."

      m = Regex.run(~r/Column "([^"]+)" does not exist on (left|right) side of join/, raw) ->
        ~s|Column "#{Enum.at(m, 1)}" isn't in the #{Enum.at(m, 2)} input. | <>
          "Join on columns both inputs have."

      m = Regex.run(~r/Unimplemented type for cast \((\w+) -> (\w+)\)/, raw) ->
        "Values of type #{Enum.at(m, 1)} can't be converted to #{Enum.at(m, 2)}. " <>
          "Use a Formula to convert one side so both have the same type."

      m = Regex.run(~r/best candidate function for the function call "([^"(]+)\(([^)]*)\)"/, raw) ->
        types = m |> Enum.at(2) |> String.replace("_LITERAL", "")

        "#{Enum.at(m, 1)} can't take values of types #{types}. " <>
          "Add explicit casts, e.g. CAST(column AS DOUBLE)."

      m = Regex.run(~r/Cannot compare values of type (\w+) and (?:type )?(\w+)/, raw) ->
        "Values of type #{Enum.at(m, 1)} and #{Enum.at(m, 2)} can't be compared. " <>
          "Use a Formula to cast one side so both have the same type."

      m = Regex.run(~r/No function matches the given name and argument types '([^']+)'/, raw) ->
        "#{Enum.at(m, 1)} doesn't take values of these types. " <>
          "Use a Formula to cast the columns to the types it takes."

      true ->
        sentence(strip_kind(first)) <> " " <> @generic
    end
  end

  # DuckDB lists candidates as "a", "b" or "t.a", "t.b".
  defp clean_candidates(names) do
    Regex.scan(~r/"(?:[^".]+\.)?([^"]+)"/, names)
    |> Enum.map(fn [_, name] -> ~s("#{name}") end)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  @types %{"INT8" => "BIGINT", "INT16" => "SMALLINT", "INT32" => "INTEGER", "INT64" => "BIGINT"}
  defp type(name), do: Map.get(@types, name, name)

  # "Binder Error: …" -> "…"
  defp strip_kind(line), do: String.replace(line, ~r/^[A-Z][A-Za-z ]* Error: /, "")

  defp sentence(""), do: "The tool failed."

  defp sentence(text) do
    text = String.trim_trailing(text, "!")
    if String.ends_with?(text, "."), do: text, else: text <> "."
  end
end
