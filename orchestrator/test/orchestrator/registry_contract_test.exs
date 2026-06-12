defmodule Orchestrator.RegistryContractTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Naming

  @moduledoc """
  Binds the VENDORED consumer registry (aqua/registry.yaml — what
  MISE_AQUA_REGISTRY_URL serves from this repo's main) to Orchestrator.Naming.
  Line-presence checks on the small, stable YAML — deliberately no YAML dep.
  Drift in either direction must break the suite (spec G5/P7).
  """

  @registry_path Path.expand("../../../aqua/registry.yaml", __DIR__)

  setup_all do
    %{registry: File.read!(@registry_path)}
  end

  test "registry file exists at the consumed path" do
    assert File.exists?(@registry_path)
  end

  test "asset template + format + os replacement are present verbatim", %{registry: reg} do
    assert reg =~ "asset: misemacs-{{.Version}}-{{.OS}}-{{.Arch}}.tar.gz"
    assert reg =~ "format: tar.gz"
    assert reg =~ "darwin: macos"
    assert reg =~ "repo_owner: djgoku"
    assert reg =~ "repo_name: misemacs"
  end

  test "checksum contract matches Naming.checksums_filename/0", %{registry: reg} do
    assert reg =~ "asset: #{Naming.checksums_filename()}"
    assert reg =~ "algorithm: sha256"
    assert reg =~ "type: github_release"
  end

  test "rendering the registry template == Naming.asset_name/3 (darwin->macos, arm64)" do
    tag = "emacs-master-2026-06-11"

    rendered =
      "misemacs-{{.Version}}-{{.OS}}-{{.Arch}}.tar.gz"
      |> String.replace("{{.Version}}", tag)
      |> String.replace("{{.OS}}", "macos")
      |> String.replace("{{.Arch}}", "arm64")

    assert rendered == Naming.asset_name(tag, "macos", "arm64")
  end

  test "every Naming.bundle_binaries/0 path appears as a files src entry", %{registry: reg} do
    for bin <- Naming.bundle_binaries() do
      assert reg =~ ~s(src: "{{.AssetWithoutExt}}/#{bin}"),
             "registry is missing files src for #{bin}"
    end
  end

  test "supported env is darwin/arm64 only", %{registry: reg} do
    assert reg =~ "- darwin/arm64"
  end
end
