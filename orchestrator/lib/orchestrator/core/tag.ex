defmodule Orchestrator.Core.Tag do
  @moduledoc """
  Pure tag computation. No IO.

  Base format is owned by `Orchestrator.Naming.tag_base/2`; this module only adds the
  `.N` collision suffix. Same-day collisions append `.1`, `.2`, ...; gaps are NOT filled
  (next = highest present suffix + 1). A base is "in use" if the bare tag OR any
  `<base>.N` exists.

  RETRY-ON-CONFLICT CONTRACT (Phase 5): `next_tag/3` is pure over a tag SNAPSHOT. The
  publisher MUST pass a freshly-fetched `existing_tags` on EACH publish attempt; on a
  `gh release create` tag collision, re-fetch the tag list and recompute — never reuse a
  previously-computed tag.
  """
  alias Orchestrator.Naming

  @spec next_tag(String.t(), String.t(), [String.t()]) :: String.t()
  def next_tag(channel, date, existing_tags) do
    base = Naming.tag_base(channel, date)
    taken = MapSet.new(existing_tags)

    if not MapSet.member?(taken, base) and not any_suffix?(taken, base) do
      base
    else
      "#{base}.#{max_suffix(existing_tags, base) + 1}"
    end
  end

  defp any_suffix?(taken, base) do
    prefix = base <> "."
    Enum.any?(taken, &String.starts_with?(&1, prefix))
  end

  defp max_suffix(tags, base) do
    prefix = base <> "."

    tags
    |> Enum.flat_map(fn
      ^base -> [0]
      tag -> suffix_of(tag, prefix)
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp suffix_of(tag, prefix) do
    case String.split(tag, prefix, parts: 2) do
      ["", n] ->
        case Integer.parse(n) do
          {i, ""} -> [i]
          _ -> []
        end

      _ ->
        []
    end
  end
end
