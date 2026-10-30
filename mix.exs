defmodule Ixpipe.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        ixpipe: [
          applications: [ixpipe_core: :permanent, ixpipe_app: :permanent],
          # `android/1` builds an APK when BAGUETTE_ANDROID is set; else a no-op.
          steps: [:assemble, &Baguette.Release.package/1, &Baguette.Release.android/1],
          baguette: [
            window: [title: "ixpipe", width: 1200, height: 800],
            android_nifs: [ixpipe_core: &libduckdb_android/1]
          ]
        ]
      ]
    ]
  end

  # Android: the DuckDB NIF links the libduckdb our CI publishes
  # (scripts/android-libduckdb.sh downloads it), which ships beside it in
  # place of the build machine's copy. DuckDB is never compiled.
  defp libduckdb_android(triple) do
    dir =
      Path.join(
        System.get_env("IXPIPE_LIBDUCKDB_ANDROID") ||
          Path.join(Mix.Project.build_path(), "android/libduckdb"),
        triple
      )

    unless File.regular?(Path.join(dir, "libduckdb.so")) do
      {_, 0} =
        System.cmd(Path.join(__DIR__, "scripts/android-libduckdb.sh"), [triple, dir],
          into: IO.stream()
        )
    end

    [
      env: [
        {"DUCKDB_LIB_DIR", dir},
        {"DUCKDB_INCLUDE_DIR", dir},
        {"DUCKDB_DOWNLOAD_LIB", "0"}
      ],
      libs: [Path.join(dir, "libduckdb.so")]
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    []
  end
end
