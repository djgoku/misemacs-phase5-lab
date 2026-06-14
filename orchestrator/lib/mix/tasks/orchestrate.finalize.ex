defmodule Mix.Tasks.Orchestrate.Finalize do
  @shortdoc "Merge per-cell manifest fragments + pick the latest tag (spec §4.4)"
  @moduledoc """
  Reads this run's `manifest-*` fragments (a dir of single-version build-manifest.json),
  merges them into the prior `latest` manifest (`Releases`), writes the merged
  `build-manifest.json` to `--out`, and prints `latest_tag=<tag>` (empty ⇒ nothing to
  finalize, no flip). The bash `pipeline/promote --manifest` then attaches + flips.

      mix orchestrate.finalize --repo <owner/repo> --fragments <dir> --out <path>
  """
  use Mix.Task
  alias Orchestrator.Orchestrate

  @switches [repo: :string, fragments: :string, out: :string]

  @impl true
  def run(argv) do
    {opts, [], []} = OptionParser.parse(argv, strict: @switches)
    main(Map.new(opts), default_deps())
  end

  @doc "exec + emit; `deps` injectable for tests."
  def main(opts, deps) do
    res = exec(opts, deps)
    emit(res, opts[:out])
    res
  end

  def exec(opts, deps \\ default_deps()) do
    fragments = read_fragments(opts[:fragments] || ".")
    prior = deps.releases.(opts[:repo])
    Orchestrate.finalize_outputs(prior, fragments, built_tags(fragments))
  end

  defp read_fragments(dir) do
    dir
    |> Path.join("**/*.json")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> File.read!() |> JSON.decode!()))
  end

  # built tags in fragment order (v1: single). Multi-version recency ordering = Phase-6 refinement.
  defp built_tags(fragments) do
    for f <- fragments, {_v, e} <- Map.get(f, "versions", %{}), do: e["released_tag"]
  end

  defp emit(%{manifest: manifest, latest_tag: tag}, out) do
    File.mkdir_p!(Path.dirname(out))
    File.write!(out, JSON.encode!(manifest) <> "\n")
    IO.puts("latest_tag=#{tag || ""}")
  end

  def default_deps, do: %{releases: &Orchestrator.Releases.Gh.last_manifest/1}
end
