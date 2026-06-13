defmodule Orchestrator.Releases do
  @moduledoc """
  IO behaviour: read the cross-run state — the `build-manifest.json` attached to the release
  marked `latest` (spec §7.2). Self-heals by scanning recent releases; returns `nil` when none
  carries one (→ `Core.Decide` treats every version as `:first_run`, the pristine-repo case).
  """
  @callback last_manifest(repo :: String.t()) :: map() | nil
end
