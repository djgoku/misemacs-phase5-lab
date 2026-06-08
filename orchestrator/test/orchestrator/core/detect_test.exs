defmodule Orchestrator.Core.DetectTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Core.Detect

  test "first run (no previous) builds" do
    assert Detect.changed?(%{upstream_sha: "a", inputs_hash: "h"}, nil) == {true, :first_run}
  end

  test "unchanged when sha and hash both match" do
    s = %{upstream_sha: "a", inputs_hash: "h"}
    assert Detect.changed?(s, s) == {false, :unchanged}
  end

  test "upstream sha change builds with :upstream_sha" do
    assert Detect.changed?(
             %{upstream_sha: "b", inputs_hash: "h"},
             %{upstream_sha: "a", inputs_hash: "h"}
           ) == {true, :upstream_sha}
  end

  test "inputs hash change builds with :inputs" do
    assert Detect.changed?(
             %{upstream_sha: "a", inputs_hash: "h2"},
             %{upstream_sha: "a", inputs_hash: "h"}
           ) == {true, :inputs}
  end

  test "empty or nil upstream sha is skipped, never treated as changed" do
    assert Detect.changed?(%{upstream_sha: "", inputs_hash: "h"}, nil) == {false, :no_upstream}

    assert Detect.changed?(
             %{upstream_sha: nil, inputs_hash: "h"},
             %{upstream_sha: "a", inputs_hash: "h"}
           ) == {false, :no_upstream}
  end
end
