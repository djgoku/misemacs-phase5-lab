defmodule Orchestrator.Releases.GhTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Releases.Gh

  test "parse_manifest/1 decodes a schema-1 manifest" do
    json = ~s({"schema":1,"versions":{"master":{"upstream_sha":"a","inputs_hash":"h"}}})
    assert %{"versions" => %{"master" => %{"upstream_sha" => "a"}}} = Gh.parse_manifest(json)
  end

  test "parse_manifest/1 is nil for non-manifest / bad json / read error" do
    assert Gh.parse_manifest(~s({"no":"versions"})) == nil
    assert Gh.parse_manifest("not json") == nil
    assert Gh.parse_manifest({:error, :enoent}) == nil
  end

  test "parse_manifest/1 unwraps a {:ok, json} File.read result" do
    assert %{"versions" => _} = Gh.parse_manifest({:ok, ~s({"versions":{}})})
  end
end
