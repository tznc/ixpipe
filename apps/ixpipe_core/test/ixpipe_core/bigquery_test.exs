defmodule IxpipeCore.BigqueryTest do
  use ExUnit.Case, async: true
  alias IxpipeCore.{Connections, Context, Table, Tools}
  alias IxpipeCore.Tools.InputBigquery

  test "a BigQuery connection names its project; credentials stay out of the file" do
    dir = Path.join(System.tmp_dir!(), "ixpipe-bq-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:error, "A bigquery connection needs a project"} =
             Connections.put(dir, %{"name" => "bq", "type" => "bigquery"})

    assert {:error, _} =
             Connections.put(dir, %{
               "name" => "bq",
               "type" => "bigquery",
               "project" => "p",
               "access_token" => "ya29"
             })

    assert :ok = Connections.put(dir, %{"name" => "bq", "type" => "bigquery", "project" => "p"})
  end

  test "input_bigquery is registered, taking bigquery connections" do
    assert Tools.lookup("input_bigquery") == InputBigquery
    assert [%{key: "connection", kinds: ["bigquery"]} | _] = InputBigquery.fields()
  end

  test "the query: SQL as written, or a whole table" do
    assert InputBigquery.sql(%{"query" => "SELECT 1"}) == "SELECT 1"
    assert InputBigquery.sql(%{"table" => "sales.orders"}) == "SELECT * FROM `sales.orders`"
  end

  test "credentials become a DuckDB secret for the project" do
    System.put_env("BQ_TOKEN_TEST", "ya29.x")
    on_exit(fn -> System.delete_env("BQ_TOKEN_TEST") end)

    assert InputBigquery.secret_sql(%{
             "name" => "bq",
             "project" => "acme",
             "access_token_env" => "BQ_TOKEN_TEST"
           }) ==
             "CREATE OR REPLACE SECRET ixpipe_bq_acme (TYPE bigquery, SCOPE 'bq://acme', ACCESS_TOKEN 'ya29.x')"

    assert InputBigquery.secret_sql(%{
             "name" => "bq",
             "project" => "acme",
             "service_account_path" => "/keys/acme.json"
           }) ==
             "CREATE OR REPLACE SECRET ixpipe_bq_acme (TYPE bigquery, SCOPE 'bq://acme', SERVICE_ACCOUNT_PATH '/keys/acme.json')"

    # Application default credentials (gcloud) need no secret.
    assert InputBigquery.secret_sql(%{"name" => "bq", "project" => "acme"}) == nil
  end

  # Needs Google Cloud credentials and DuckDB's community bigquery extension
  # (downloaded on first use): IXPIPE_BQ_PROJECT bills the query.
  @tag :bigquery
  test "reads a public dataset" do
    dir = Path.join(System.tmp_dir!(), "ixpipe-bq-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    :ok =
      Connections.put(dir, %{
        "name" => "bq",
        "type" => "bigquery",
        "project" => System.fetch_env!("IXPIPE_BQ_PROJECT")
      })

    df =
      InputBigquery.run(
        %{},
        %{
          "connection" => "bq",
          "_home" => dir,
          "query" =>
            "SELECT name FROM `bigquery-public-data.usa_names.usa_1910_2013` ORDER BY name LIMIT 2"
        },
        Context.new()
      )

    assert Table.count(df) == 2
  end
end
