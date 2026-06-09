defmodule Orchestrator.VersionLayoutTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Manifest

  @repo_root Path.expand("../../..", __DIR__)

  test "version_input_files/1 lists the three per-version build inputs (relative to repo root)" do
    assert Manifest.version_input_files("master") == [
             "versions/master/mise.toml",
             "versions/master/pixi.toml",
             "versions/master/pixi.lock"
           ]
  end

  test "every versions.toml entry has its versions/<name>/ build inputs committed on disk" do
    {:ok, vbin} = File.read(Path.join(@repo_root, "versions.toml"))
    {:ok, vmap} = Toml.decode(vbin)
    names = Map.keys(Map.get(vmap, "versions", %{}))

    assert names != [], "versions.toml has no [versions.*] entries"
    assert Manifest.missing_version_files(@repo_root, names) == []
  end
end
