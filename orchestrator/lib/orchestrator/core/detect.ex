defmodule Orchestrator.Core.Detect do
  @moduledoc """
  Pure change detection. No IO.

  The IO edge (Phase 5 `Upstream` adapter) MUST normalize an absent/unresolvable ref to
  `upstream_sha: nil` (or ""), never an `:error` tuple or a missing key — an empty
  upstream sha is a SKIP (`:no_upstream`), never a rebuild.
  """

  @type state :: %{upstream_sha: String.t() | nil, inputs_hash: String.t()}
  @type reason :: :first_run | :upstream_sha | :inputs | :no_upstream | :unchanged

  @doc "Whether a version changed vs its last-released `previous` state (nil on first run)."
  @spec changed?(state(), state() | nil) :: {boolean(), reason()}
  def changed?(%{upstream_sha: cur_sha}, _previous) when cur_sha in [nil, ""],
    do: {false, :no_upstream}

  def changed?(_current, nil), do: {true, :first_run}

  def changed?(%{upstream_sha: cur_sha, inputs_hash: cur_hash}, %{
        upstream_sha: prev_sha,
        inputs_hash: prev_hash
      }) do
    cond do
      cur_sha != prev_sha -> {true, :upstream_sha}
      cur_hash != prev_hash -> {true, :inputs}
      true -> {false, :unchanged}
    end
  end
end
