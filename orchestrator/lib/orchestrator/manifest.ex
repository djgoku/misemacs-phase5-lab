defmodule Orchestrator.Manifest do
  @moduledoc """
  The build matrix: versions.toml × targets.toml → job list.
  Adding a version or target is a data edit to those files; no code change.

  INVARIANT: a version's table key (`job.name`) is BOTH the `versions/<name>/` directory
  name AND the join key used everywhere else (`current_states[name]`, the
  `build-manifest.json` `"versions"` map, `Decide.matrix/2`). Keep the table key == the
  git ref where practical (e.g. `[versions."emacs-30.2"]`); `channel` is the short form.

  A `job` is a SUPERSET of what `Decide.plan/4` needs (which takes `%{name,channel,ref}`):
  do not pass a `job` where a `version` is expected, or `:os/:arch/...` leak into the plan.

  Targets are FAIL-CLOSED: a target with no explicit `enabled = true` is disabled.
  """

  @type job :: %{
          name: String.t(),
          channel: String.t(),
          ref: String.t(),
          target: String.t(),
          os: String.t(),
          arch: String.t(),
          runner: String.t()
        }

  @doc "Pure cross-product of versions × ENABLED targets (fail-closed), sorted for determinism."
  @spec jobs(map(), map()) :: [job()]
  def jobs(versions, targets) do
    enabled = for {tn, t} <- targets, Map.get(t, "enabled", false), do: {tn, t}

    for {vn, v} <- versions, {tn, t} <- enabled do
      %{
        name: vn,
        channel: v["channel"],
        ref: v["ref"],
        target: tn,
        os: t["os"],
        arch: t["arch"],
        runner: t["runner"]
      }
    end
    |> Enum.sort_by(&{&1.name, &1.target})
  end

  @doc "Read + parse both TOML manifests into a job list."
  @spec load(Path.t(), Path.t()) :: {:ok, [job()]} | {:error, term()}
  def load(versions_path, targets_path) do
    with {:ok, vbin} <- File.read(versions_path),
         {:ok, tbin} <- File.read(targets_path),
         {:ok, vmap} <- Toml.decode(vbin),
         {:ok, tmap} <- Toml.decode(tbin) do
      {:ok, jobs(Map.get(vmap, "versions", %{}), Map.get(tmap, "targets", %{}))}
    end
  end
end
