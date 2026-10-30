defmodule IxpipeCore.Functions do
  @moduledoc """
  A reference of the DuckDB SQL functions most used in expressions (Filter,
  Formula and the formula tools), for an editor to search and insert: each
  with a `category`, a `signature` (what an editor inserts), a one-line
  `description` and an `example` that evaluates to `result` (tested).
  """

  @categories ~w(string math date conditional conversion)

  @type function_ref :: %{
          name: String.t(),
          category: String.t(),
          signature: String.t(),
          description: String.t(),
          example: String.t(),
          result: String.t()
        }

  # {name, signature, description, example, result}, by category.
  @functions [
    {"string",
     [
       {"upper", "upper(text)", "Converts text to capitals.", "upper('eu')", "EU"},
       {"lower", "lower(text)", "Converts text to lower case.", "lower('EU')", "eu"},
       {"trim", "trim(text)", "Removes spaces from both ends.", "trim('  a b ')", "a b"},
       {"length", "length(text)", "Counts the characters.", "length('hello')", "5"},
       {"concat", "concat(a, b, ...)", "Joins values as text; NULLs count as empty.",
        "concat('a', NULL, 'b')", "ab"},
       {"substring", "substring(text, start, length)",
        "Takes length characters from start (1 is the first).", "substring('ixpipe', 3, 4)",
        "pipe"},
       {"left", "left(text, n)", "The first n characters.", "left('ixpipe', 2)", "ix"},
       {"right", "right(text, n)", "The last n characters.", "right('ixpipe', 4)", "pipe"},
       {"replace", "replace(text, find, with)", "Replaces every find with with.",
        "replace('a-b-c', '-', '/')", "a/b/c"},
       {"contains", "contains(text, find)", "True when text contains find.",
        "contains('ixpipe', 'pipe')", "true"},
       {"starts_with", "starts_with(text, prefix)", "True when text starts with prefix.",
        "starts_with('ixpipe', 'ix')", "true"},
       {"split_part", "split_part(text, separator, n)",
        "The nth piece of text split on separator.", "split_part('a,b,c', ',', 2)", "b"},
       {"regexp_matches", "regexp_matches(text, pattern)",
        "True when the regular expression matches.", "regexp_matches('ab12', '[0-9]+')", "true"},
       {"regexp_replace", "regexp_replace(text, pattern, with, 'g')",
        "Replaces regular expression matches; 'g' for all of them.",
        "regexp_replace('a1b2', '[0-9]', '', 'g')", "ab"},
       {"lpad", "lpad(text, width, fill)", "Pads text on the left to width.", "lpad('7', 3, '0')",
        "007"}
     ]},
    {"math",
     [
       {"round", "round(number, digits)", "Rounds to digits decimal places.", "round(3.14159, 2)",
        "3.14"},
       {"floor", "floor(number)", "Rounds down to a whole number.", "floor(2.7)", "2"},
       {"ceil", "ceil(number)", "Rounds up to a whole number.", "ceil(2.1)", "3"},
       {"abs", "abs(number)", "The value without its sign.", "abs(-4)", "4"},
       {"power", "power(base, exponent)", "base raised to exponent.", "power(2, 10)", "1024.0"},
       {"sqrt", "sqrt(number)", "The square root.", "sqrt(16)", "4.0"},
       {"ln", "ln(number)", "The natural logarithm.", "round(ln(1), 2)", "0.0"},
       {"mod", "mod(a, b)", "The remainder of a divided by b (also a % b).", "mod(17, 5)", "2"},
       {"greatest", "greatest(a, b, ...)", "The largest of its arguments.", "greatest(3, 9, 4)",
        "9"},
       {"least", "least(a, b, ...)", "The smallest of its arguments.", "least(3, 9, 4)", "3"},
       {"random", "random()", "A random number from 0 to 1.", "random() < 1", "true"}
     ]},
    {"date",
     [
       {"current_date", "current_date", "Today's date.", "current_date IS NOT NULL", "true"},
       {"date_diff", "date_diff('day', start, end)",
        "The number of units (day, month, year…) from start to end.",
        "date_diff('day', DATE '2024-01-01', DATE '2024-03-01')", "60"},
       {"interval", "date + INTERVAL n unit", "Adds days, months or years to a date.",
        "DATE '2024-01-31' + INTERVAL 1 MONTH", "2024-02-29 00:00:00"},
       {"date_trunc", "date_trunc('month', date)",
        "The start of the date's month (or year, week, day…).",
        "date_trunc('month', DATE '2024-03-15')", "2024-03-01 00:00:00"},
       {"date_part", "date_part('year', date)", "One part of a date: year, month, day, dow…",
        "date_part('year', DATE '2024-03-15')", "2024"},
       {"strftime", "strftime(date, format)", "Writes a date as text, e.g. '%d/%m/%Y'.",
        "strftime(DATE '2024-03-05', '%d/%m/%Y')", "05/03/2024"},
       {"strptime", "strptime(text, format)", "Reads text as a timestamp in a format.",
        "strptime('05/03/2024', '%d/%m/%Y')", "2024-03-05 00:00:00"},
       {"make_date", "make_date(year, month, day)", "A date from its parts.",
        "make_date(2024, 3, 5)", "2024-03-05"},
       {"last_day", "last_day(date)", "The last day of the date's month.",
        "last_day(DATE '2024-02-10')", "2024-02-29"},
       {"dayname", "dayname(date)", "The weekday's name.", "dayname(DATE '2024-03-05')",
        "Tuesday"}
     ]},
    {"conditional",
     [
       {"case", "CASE WHEN condition THEN a ELSE b END",
        "a where the condition holds, otherwise b.",
        "CASE WHEN 5 > 3 THEN 'big' ELSE 'small' END", "big"},
       {"if", "if(condition, a, b)", "a when the condition holds, otherwise b.",
        "if(2 > 3, 'yes', 'no')", "no"},
       {"coalesce", "coalesce(a, b, ...)", "The first argument that is not NULL.",
        "coalesce(NULL, 'fallback')", "fallback"},
       {"nullif", "nullif(a, b)", "NULL when a equals b, otherwise a.", "nullif(0, 0) IS NULL",
        "true"},
       {"is null", "value IS NULL", "True when the value is NULL.", "NULL IS NULL", "true"},
       {"in", "value IN (a, b, ...)", "True when the value is one of the list.",
        "'eu' IN ('eu', 'us')", "true"},
       {"between", "value BETWEEN low AND high", "True when low <= value <= high.",
        "5 BETWEEN 1 AND 10", "true"},
       {"like", "text LIKE pattern", "Matches a pattern: % any text, _ one character.",
        "'ixpipe' LIKE 'ix%'", "true"}
     ]},
    {"conversion",
     [
       {"cast", "CAST(value AS type)", "Converts to a type: INTEGER, DOUBLE, VARCHAR, DATE…",
        "CAST('42' AS INTEGER) + 1", "43"},
       {"try_cast", "TRY_CAST(value AS type)", "Like CAST, but NULL when it cannot convert.",
        "TRY_CAST('abc' AS INTEGER) IS NULL", "true"},
       {"varchar", "value::VARCHAR", "Converts any value to text.", "42::VARCHAR || '!'", "42!"},
       {"double", "value::DOUBLE", "Converts text to a number.", "'3.5'::DOUBLE * 2", "7.0"},
       {"date", "value::DATE", "Converts ISO text (2024-03-05) to a date.", "'2024-03-05'::DATE",
        "2024-03-05"},
       {"try_strptime", "try_strptime(text, format)",
        "Reads text as a timestamp; NULL when it does not match.",
        "try_strptime('nope', '%Y') IS NULL", "true"},
       {"format", "format('{}: {}', a, b)", "Fills {} placeholders with values, as text.",
        "format('{} rows', 4)", "4 rows"},
       {"typeof", "typeof(value)", "The value's type, by name.", "typeof(1.5)", "DECIMAL(2,1)"}
     ]}
  ]

  @all for {category, functions} <- @functions,
           {name, signature, description, example, result} <- functions,
           do: %{
             name: name,
             category: category,
             signature: signature,
             description: description,
             example: example,
             result: result
           }

  @doc "The categories, in the order an editor shows them."
  @spec categories() :: [String.t()]
  def categories, do: @categories

  @doc "Every function, by category."
  @spec all() :: [function_ref()]
  def all, do: @all

  @doc """
  The functions in `category` (all when nil) whose name, signature or
  description contains `query`, ignoring case; names that start with it
  first.
  """
  @spec search(String.t(), String.t() | nil) :: [function_ref()]
  def search(query, category) do
    q = query |> String.trim() |> String.downcase()

    @all
    |> Enum.filter(&(category in [nil, &1.category]))
    |> Enum.filter(fn f ->
      Enum.any?([f.name, f.signature, f.description], &String.contains?(String.downcase(&1), q))
    end)
    |> Enum.sort_by(&(not String.starts_with?(&1.name, q)))
  end

  @doc """
  Up to five functions whose name starts with the word at the end of
  `text`: completions for what is being typed. None after a space or
  symbol.
  """
  @spec complete(String.t()) :: [function_ref()]
  def complete(text) do
    case Regex.run(~r/([A-Za-z_][A-Za-z0-9_]*)$/, text) do
      [_, word] ->
        word = String.downcase(word)

        @all
        |> Enum.filter(&String.starts_with?(&1.name, word))
        |> Enum.reject(&(&1.name == word))
        |> Enum.take(5)

      nil ->
        []
    end
  end

  @doc "The word `complete/1` completes: the identifier at the end of `text`."
  @spec word(String.t()) :: String.t()
  def word(text) do
    case Regex.run(~r/[A-Za-z_][A-Za-z0-9_]*$/, text) do
      [word] -> word
      nil -> ""
    end
  end
end
