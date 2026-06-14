defmodule Mix.Tasks.Orchestrate.FinalizeTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    dir = Path.join(System.tmp_dir!(), "frags-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, out: Path.join(dir, "build-manifest.json")}
  end

  test "merges fragments into nil prior, writes manifest, prints latest_tag", %{dir: dir, out: out} do
    File.write!(Path.join(dir, "manifest-master.json"),
      ~s({"schema":1,"versions":{"master":{"released_tag":"emacs-master-2026-06-13","inputs_hash":"h"}}}))

    printed =
      capture_io(fn ->
        Mix.Tasks.Orchestrate.Finalize.main(
          %{repo: "o/r", fragments: dir, out: out},
          %{releases: fn _ -> nil end}
        )
      end)

    assert printed =~ "latest_tag=emacs-master-2026-06-13"
    written = out |> File.read!() |> JSON.decode!()
    assert written["versions"]["master"]["inputs_hash"] == "h"
  end

  test "zero fragments => latest_tag= (empty, no flip)", %{dir: dir, out: out} do
    printed =
      capture_io(fn ->
        Mix.Tasks.Orchestrate.Finalize.main(%{repo: "o/r", fragments: dir, out: out}, %{releases: fn _ -> nil end})
      end)

    assert printed =~ ~r/^latest_tag=\s*$/m
  end

  test "merges a fragment on top of a prior manifest from Releases", %{dir: dir, out: out} do
    File.write!(Path.join(dir, "manifest-master.json"),
      ~s({"versions":{"master":{"released_tag":"new"}}}))

    prior = %{"schema" => 1, "versions" => %{"emacs-30.2" => %{"released_tag" => "keep"}}}

    capture_io(fn ->
      Mix.Tasks.Orchestrate.Finalize.main(%{repo: "o/r", fragments: dir, out: out}, %{releases: fn _ -> prior end})
    end)

    written = out |> File.read!() |> JSON.decode!()
    assert written["versions"]["master"]["released_tag"] == "new"
    assert written["versions"]["emacs-30.2"]["released_tag"] == "keep"
  end
end
