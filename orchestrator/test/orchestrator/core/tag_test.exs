defmodule Orchestrator.Core.TagTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Core.Tag
  alias Orchestrator.Naming

  test "no collision returns the bare tag" do
    assert Tag.next_tag("master", "2026-06-05", []) == "emacs-master-2026-06-05"

    assert Tag.next_tag("master", "2026-06-05", ["emacs-master-2026-06-04"]) ==
             "emacs-master-2026-06-05"
  end

  test "first collision appends .1" do
    assert Tag.next_tag("master", "2026-06-05", ["emacs-master-2026-06-05"]) ==
             "emacs-master-2026-06-05.1"
  end

  test "second collision appends .2" do
    existing = ["emacs-master-2026-06-05", "emacs-master-2026-06-05.1"]
    assert Tag.next_tag("master", "2026-06-05", existing) == "emacs-master-2026-06-05.2"
  end

  test "gaps are not filled (next = highest suffix + 1)" do
    existing = ["emacs-master-2026-06-05", "emacs-master-2026-06-05.2"]
    assert Tag.next_tag("master", "2026-06-05", existing) == "emacs-master-2026-06-05.3"
  end

  test "base is in-use if only a suffixed tag exists (bare base missing)" do
    assert Tag.next_tag("master", "2026-06-05", ["emacs-master-2026-06-05.1"]) ==
             "emacs-master-2026-06-05.2"
  end

  test "numeric (not lexical) suffix ordering: .9 + .10 -> .11" do
    existing = [
      "emacs-master-2026-06-05",
      "emacs-master-2026-06-05.9",
      "emacs-master-2026-06-05.10"
    ]

    assert Tag.next_tag("master", "2026-06-05", existing) == "emacs-master-2026-06-05.11"
  end

  test "malformed suffixes and other channels/dates are ignored" do
    existing = [
      "emacs-master-2026-06-05",
      "emacs-master-2026-06-05.x",
      "emacs-30.2-2026-06-05",
      "emacs-master-2026-06-04.5"
    ]

    assert Tag.next_tag("master", "2026-06-05", existing) == "emacs-master-2026-06-05.1"
  end

  test "retry contract: recompute on a grown snapshot advances the suffix" do
    t1 = Tag.next_tag("master", "2026-06-05", [])
    assert t1 == "emacs-master-2026-06-05"
    t2 = Tag.next_tag("master", "2026-06-05", [t1])
    assert t2 == "emacs-master-2026-06-05.1"
    t3 = Tag.next_tag("master", "2026-06-05", [t1, t2])
    assert t3 == "emacs-master-2026-06-05.2"
  end

  test "asset name round-trips from the computed tag (aqua template)" do
    tag = Tag.next_tag("master", "2026-06-05", [])
    name = Naming.asset_name(tag, "macos", "arm64")
    assert name == "misemacs-emacs-master-2026-06-05-macos-arm64.tar.gz"
  end
end
