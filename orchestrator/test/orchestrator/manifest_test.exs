defmodule Orchestrator.ManifestTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Manifest

  @fixtures Path.expand("../support/fixtures", __DIR__)
  @repo_root Path.expand("../../..", __DIR__)

  test "jobs/2 crosses versions × enabled targets" do
    versions = %{
      "master" => %{"channel" => "master", "ref" => "master"},
      "emacs-30.2" => %{"channel" => "30.2", "ref" => "emacs-30.2"}
    }

    targets = %{
      "macos-arm64" => %{
        "os" => "macos",
        "arch" => "arm64",
        "runner" => "macos-14",
        "enabled" => true
      }
    }

    jobs = Manifest.jobs(versions, targets)
    assert length(jobs) == 2
    assert Enum.any?(jobs, &(&1.name == "master" and &1.os == "macos" and &1.arch == "arm64"))
    assert Enum.any?(jobs, &(&1.name == "emacs-30.2" and &1.channel == "30.2"))
  end

  test "jobs/2 omits disabled targets" do
    versions = %{"master" => %{"channel" => "master", "ref" => "master"}}

    targets = %{
      "macos-arm64" => %{
        "os" => "macos",
        "arch" => "arm64",
        "runner" => "macos-14",
        "enabled" => true
      },
      "linux-arm64" => %{
        "os" => "linux",
        "arch" => "arm64",
        "runner" => "ubuntu-24.04-arm",
        "enabled" => false
      }
    }

    jobs = Manifest.jobs(versions, targets)
    assert length(jobs) == 1
    assert hd(jobs).target == "macos-arm64"
  end

  test "a target without explicit enabled=true is omitted (fail-closed)" do
    versions = %{"master" => %{"channel" => "master", "ref" => "master"}}
    targets = %{"macos-arm64" => %{"os" => "macos", "arch" => "arm64", "runner" => "macos-14"}}
    assert Manifest.jobs(versions, targets) == []
  end

  test "job.name equals the version table key (join-key invariant)" do
    versions = %{"emacs-30.2" => %{"channel" => "30.2", "ref" => "emacs-30.2"}}

    targets = %{
      "macos-arm64" => %{
        "os" => "macos",
        "arch" => "arm64",
        "runner" => "macos-14",
        "enabled" => true
      }
    }

    [job] = Manifest.jobs(versions, targets)
    assert job.name == "emacs-30.2"
    assert job.name == job.ref
  end

  test "load/2 parses TOML fixtures into a job list" do
    {:ok, jobs} =
      Manifest.load(Path.join(@fixtures, "versions.toml"), Path.join(@fixtures, "targets.toml"))

    # 2 versions × 1 enabled target (linux disabled)
    assert length(jobs) == 2
    assert Enum.all?(jobs, &(&1.target == "macos-arm64"))
  end

  test "the committed repo-root manifest parses and includes master/macos-arm64" do
    {:ok, jobs} =
      Manifest.load(Path.join(@repo_root, "versions.toml"), Path.join(@repo_root, "targets.toml"))

    assert Enum.any?(jobs, &(&1.name == "master" and &1.target == "macos-arm64"))
  end
end
