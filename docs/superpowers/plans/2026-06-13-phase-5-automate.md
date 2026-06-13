# Phase 5 — Automate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the lab-proven Phase-4 pipeline into a daily, change-gated GitHub Actions workflow (`decide` → `build` → `finalize`) that produces `djgoku/misemacs`'s first automated releases — proven end-to-end on a throwaway repo, then pushed up clean.

**Architecture:** Three jobs on `macos-26`/`ubuntu`. `decide` (Elixir `mix orchestrate.decide`) wires `Upstream`/`Releases`/`Toolchain` IO behaviours to the pure `Core.{Detect,Decide}` and emits a dynamic matrix + flags as job outputs. `build` (matrix) reuses the bash `build`→`relocate`→`publish` and uploads a per-cell manifest fragment. `finalize` (Elixir `mix orchestrate.finalize`) merges fragments into the prior `latest` manifest, picks the latest tag (`Core.Latest`), and reuses bash `promote --manifest` to attach + flip. D4 split throughout: Elixir decides, bash writes.

**Tech Stack:** Elixir 1.20 / ExUnit (orchestrator), bash 3.2 (pipeline glue), GitHub Actions (YAML), mise (provisioning), `gh`/`git` (IO). Built-in `JSON`; only dep is `{:toml, "~> 0.7"}`.

**Spec:** `docs/superpowers/specs/2026-06-13-phase-5-automate-design.md` (committed `42c23ad`). Reference its §-numbers; this plan implements it task-by-task.

---

## File Structure

**New Elixir** (`orchestrator/lib/orchestrator/`):
- `toolchain.ex` — `Orchestrator.Toolchain` behaviour (`clt_fingerprint/0`); `toolchain/macos.ex` — `Toolchain.Macos` adapter (pure `normalize/3` + IO).
- `upstream.ex` — `Orchestrator.Upstream` behaviour (`resolve/1`); `upstream/git_ls_remote.ex` — `Upstream.GitLsRemote` (pure `parse/2` + IO).
- `releases.ex` — `Orchestrator.Releases` behaviour (`last_manifest/1`); `releases/gh.ex` — `Releases.Gh` (pure `parse_manifest/1` + IO).
- `orchestrate.ex` — `Orchestrator.Orchestrate` (pure `decide_outputs/7` + `finalize_outputs/3`).
- `lib/mix/tasks/orchestrate.decide.ex`, `orchestrate.finalize.ex` — thin IO tasks.

**Modified Elixir:** `core/hash.ex` (`toolchain_hash/3`), `core/decide.ex` (`force/3`), `manifest.ex` (`versions!/1`, `merge/2`), `lib/mix/tasks/release.manifest.ex` (`--clt-fingerprint`).

**Modified config/bash:** `targets.toml` + `orchestrator/test/support/fixtures/targets.toml` (`runner = macos-26`), `pipeline/publish` (write `published-tag.txt`), `pipeline/promote` (`--manifest`), `mise.toml` (`[tasks.decide]`, `[tasks.finalize]`).

**New:** `.github/workflows/daily.yml`.

**Tests:** new `toolchain_test.exs`, `upstream_test.exs`, `releases_test.exs`, `orchestrate_test.exs`, `test/mix/tasks/orchestrate_decide_test.exs`, `orchestrate_finalize_test.exs`; updated `hash_test.exs`, `manifest_test.exs`, `decide_test.exs`, `release_manifest_test.exs`.

**Task groups:** A = Elixir/bash primitives (1–11), B = workflow + throwaway validation (12–13), C = docs + cutover (14–15).

---

## Task 1: Switch the runner to macos-26

**Files:**
- Modify: `targets.toml:5`
- Modify: `orchestrator/test/support/fixtures/targets.toml:4`

No test asserts the runner *value* (only `name`/`os`/`arch`/`target`), so the suite stays green.

- [ ] **Step 1: Edit the repo target**

In `targets.toml` change the runner line to:

```toml
runner = "macos-26"   # arm64 hosted runner (bare label = arm64; spec V3)
```

- [ ] **Step 2: Edit the test fixture**

In `orchestrator/test/support/fixtures/targets.toml` change `runner = "macos-14"` to `runner = "macos-26"`.

- [ ] **Step 3: Verify the suite is still green**

Run: `cd orchestrator && mix test`
Expected: PASS (same count as before — no assertion depended on the runner value).

- [ ] **Step 4: Commit**

```bash
git add targets.toml orchestrator/test/support/fixtures/targets.toml
git commit -m "feat(phase5): target macos-26 (arm64 bare label) for decide+build"
```

---

## Task 2: `Orchestrator.Toolchain` behaviour + `Toolchain.Macos` adapter (Decision E capture)

**Files:**
- Create: `orchestrator/lib/orchestrator/toolchain.ex`
- Create: `orchestrator/lib/orchestrator/toolchain/macos.ex`
- Test: `orchestrator/test/orchestrator/toolchain_test.exs`

- [ ] **Step 1: Write the failing test**

Create `orchestrator/test/orchestrator/toolchain_test.exs`:

```elixir
defmodule Orchestrator.Toolchain.MacosTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Toolchain.Macos

  @clang """
  Apple clang version 21.0.0 (clang-2100.1.1.101)
  Target: arm64-apple-darwin25.5.0
  Thread model: posix
  InstalledDir: /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
  """

  test "normalize/3 keeps only the Apple-clang line and is stable for identical inputs" do
    h = Macos.normalize("/Applications/Xcode.app/Contents/Developer\n", @clang, "26.5\n")
    assert String.starts_with?(h, "sha256:")
    assert h == Macos.normalize("/Applications/Xcode.app/Contents/Developer", @clang, "26.5")
  end

  test "normalize/3 ignores the host-OS-volatile Target line" do
    a = "Apple clang version 21.0.0 (clang-2100.1.1.101)\nTarget: arm64-apple-darwin25.5.0\n"
    b = "Apple clang version 21.0.0 (clang-2100.1.1.101)\nTarget: arm64-apple-darwin25.6.0\n"
    assert Macos.normalize("/p", a, "26.5") == Macos.normalize("/p", b, "26.5")
  end

  test "normalize/3 flips on a clang-build, SDK, or developer-dir change" do
    base = Macos.normalize("/p", "Apple clang version 21.0.0 (clang-2100.1.1.101)\n", "26.5")
    assert base != Macos.normalize("/p", "Apple clang version 21.0.0 (clang-2100.1.1.102)\n", "26.5")
    assert base != Macos.normalize("/p", "Apple clang version 21.0.0 (clang-2100.1.1.101)\n", "26.6")
    assert base != Macos.normalize("/q", "Apple clang version 21.0.0 (clang-2100.1.1.101)\n", "26.5")
  end

  @tag :macos
  test "clt_fingerprint/0 captures a stable sha on a real macOS host (run-to-run)" do
    h = Macos.clt_fingerprint()
    assert String.starts_with?(h, "sha256:")
    assert h == Macos.clt_fingerprint()
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd orchestrator && mix test test/orchestrator/toolchain_test.exs`
Expected: FAIL — `Orchestrator.Toolchain.Macos` is undefined.

- [ ] **Step 3: Create the behaviour**

Create `orchestrator/lib/orchestrator/toolchain.ex`:

```elixir
defmodule Orchestrator.Toolchain do
  @moduledoc """
  IO behaviour for the macOS toolchain (CLT/SDK) fingerprint — Decision E (spec §8/§4.5).
  Folded into `Core.Hash.toolchain_hash/3` so a runner-image bump (new clang/SDK) triggers
  a rebuild. Captured identically by `mix orchestrate.decide` and the build cell's
  `mix release.manifest` (both on macos-26) so detect and the recorded fingerprint agree.
  """
  @callback clt_fingerprint() :: String.t()
end
```

- [ ] **Step 4: Create the adapter**

Create `orchestrator/lib/orchestrator/toolchain/macos.ex`:

```elixir
defmodule Orchestrator.Toolchain.Macos do
  @moduledoc """
  Default `Orchestrator.Toolchain` — the STABLE macOS CLT/SDK identity: `xcode-select -p`,
  the `Apple clang version …(clang-<build>)` line of `clang --version` (the host-OS-volatile
  `Target:`/`InstalledDir`/`Thread model` lines dropped), and `xcrun --show-sdk-version`.
  Reasoning (`normalize/3`) is pure; only `clt_fingerprint/0` shells out.
  """
  @behaviour Orchestrator.Toolchain
  alias Orchestrator.Core.Hash

  @impl true
  def clt_fingerprint do
    normalize(
      cmd("xcode-select", ["-p"]),
      cmd("clang", ["--version"]),
      cmd("xcrun", ["--show-sdk-version"])
    )
  end

  @doc "Pure: the three command outputs → a stable `sha256:` fingerprint."
  @spec normalize(String.t(), String.t(), String.t()) :: String.t()
  def normalize(xcode_path, clang_version, sdk_version) do
    Hash.fingerprint([
      {"xcode_select", String.trim(xcode_path)},
      {"clang", clang_line(clang_version)},
      {"sdk", String.trim(sdk_version)}
    ])
  end

  defp clang_line(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.find("", &String.starts_with?(&1, "Apple clang version "))
    |> String.trim()
  end

  defp cmd(bin, args) do
    {out, 0} = System.cmd(bin, args, stderr_to_stdout: true)
    out
  end
end
```

- [ ] **Step 5: Run the test (off-macOS the `:macos` case is excluded)**

Run: `cd orchestrator && mix test test/orchestrator/toolchain_test.exs`
Expected: PASS (3 pure tests; the `@tag :macos` one runs only on Darwin per `test_helper.exs`).

- [ ] **Step 6: Commit**

```bash
git add orchestrator/lib/orchestrator/toolchain.ex orchestrator/lib/orchestrator/toolchain/macos.ex orchestrator/test/orchestrator/toolchain_test.exs
git commit -m "feat(phase5): Toolchain behaviour + Macos CLT/SDK fingerprint (Decision E)"
```

---

## Task 3: `Hash.toolchain_hash/3` + wire `release.manifest --clt-fingerprint`

**Files:**
- Modify: `orchestrator/lib/orchestrator/core/hash.ex:22-25`
- Modify: `orchestrator/test/orchestrator/core/hash_test.exs:18-23`
- Modify: `orchestrator/lib/mix/tasks/release.manifest.ex:15,28-44`
- Modify: `orchestrator/test/mix/tasks/release_manifest_test.exs:25-41,53-62`

- [ ] **Step 1: Update the Hash test to the 3-arity form (failing)**

In `orchestrator/test/orchestrator/core/hash_test.exs` replace the `toolchain_hash/2` test with:

```elixir
  test "toolchain_hash/3 is stable and flips on any input incl. clt" do
    h = Hash.toolchain_hash("a", "b", "c")
    assert h == Hash.toolchain_hash("a", "b", "c")
    refute h == Hash.toolchain_hash("a", "b2", "c")
    refute h == Hash.toolchain_hash("a2", "b", "c")
    refute h == Hash.toolchain_hash("a", "b", "c2")
  end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd orchestrator && mix test test/orchestrator/core/hash_test.exs`
Expected: FAIL — `toolchain_hash/3` undefined.

- [ ] **Step 3: Change `toolchain_hash` to arity 3**

In `orchestrator/lib/orchestrator/core/hash.ex` replace the `toolchain_hash/2` doc+function with:

```elixir
  @doc "Toolchain hash = sha256 of mise.toml ⧺ mise.lock ⧺ CLT/SDK fingerprint (spec §8, Decision E)."
  @spec toolchain_hash(iodata(), iodata(), iodata()) :: String.t()
  def toolchain_hash(mise_toml, mise_lock, clt) do
    fingerprint([{"mise_toml", mise_toml}, {"mise_lock", mise_lock}, {"clt", clt}])
  end
```

- [ ] **Step 4: Wire `release.manifest` to capture/accept the CLT fingerprint**

In `orchestrator/lib/mix/tasks/release.manifest.ex`: add `clt_fingerprint: :string` to `@switches`, and in `run/1` compute `clt` and pass it to `toolchain_hash/3`. The `@switches` line becomes:

```elixir
  @switches [version: :string, tag: :string, upstream_sha: :string, out: :string, root: :string, clt_fingerprint: :string]
```

Replace the `inputs_hash = ...` block with:

```elixir
    clt = opts[:clt_fingerprint] || Orchestrator.Toolchain.Macos.clt_fingerprint()

    inputs_hash =
      Hash.version_fingerprint(%{
        toolchain_hash:
          Hash.toolchain_hash(
            File.read!(Path.join(root, "mise.toml")),
            File.read!(Path.join(root, "mise.lock")),
            clt
          ),
        upstream_sha: sha,
        mise_toml: mise_toml,
        pixi_toml: pixi_toml,
        pixi_lock: pixi_lock
      })
```

(Production omits `--clt-fingerprint` on the macos-26 cell ⇒ `Toolchain.Macos` runs, matching `decide`; tests inject a fixture so ubuntu never shells `clang`.)

- [ ] **Step 5: Update `release_manifest_test.exs` to inject a fixture clt**

In `orchestrator/test/mix/tasks/release_manifest_test.exs`, in the `run/3` helper append `--clt-fingerprint`/`"clt-fixture"` to the default `args`:

```elixir
      ] ++ ["--clt-fingerprint", "clt-fixture"] ++ extra
```

And update the `expected` toolchain_hash call to arity 3:

```elixir
        toolchain_hash: Hash.toolchain_hash("# repo mise.toml\n", "# repo mise.lock\n", "clt-fixture"),
```

- [ ] **Step 6: Run the affected suites**

Run: `cd orchestrator && mix test test/orchestrator/core/hash_test.exs test/mix/tasks/release_manifest_test.exs`
Expected: PASS.

- [ ] **Step 7: Full suite + warnings-as-errors gate**

Run: `mise run test`
Expected: PASS, no warnings.

- [ ] **Step 8: Commit**

```bash
git add orchestrator/lib/orchestrator/core/hash.ex orchestrator/test/orchestrator/core/hash_test.exs orchestrator/lib/mix/tasks/release.manifest.ex orchestrator/test/mix/tasks/release_manifest_test.exs
git commit -m "feat(phase5): fold CLT/SDK into toolchain_hash/3; release.manifest --clt-fingerprint"
```

---

## Task 4: `Orchestrator.Upstream` behaviour + `Upstream.GitLsRemote` adapter

**Files:**
- Create: `orchestrator/lib/orchestrator/upstream.ex`
- Create: `orchestrator/lib/orchestrator/upstream/git_ls_remote.ex`
- Test: `orchestrator/test/orchestrator/upstream_test.exs`

- [ ] **Step 1: Write the failing test**

Create `orchestrator/test/orchestrator/upstream_test.exs`:

```elixir
defmodule Orchestrator.Upstream.GitLsRemoteTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Upstream.GitLsRemote, as: U

  test "parse/2 picks the refs/heads/<ref> sha" do
    out = "deadbeef\trefs/heads/master\ncafef00d\trefs/tags/v1\n"
    assert U.parse(out, "master") == "deadbeef"
  end

  test "parse/2 picks refs/tags/<ref> for a tag ref (ignoring the peeled ^{} row)" do
    out = "aaa111\trefs/tags/emacs-30.2\nbbb222\trefs/tags/emacs-30.2^{}\n"
    assert U.parse(out, "emacs-30.2") == "aaa111"
  end

  test "parse/2 falls back to the first row when no exact ref match" do
    assert U.parse("abc\trefs/heads/foo\n", "master") == "abc"
  end

  test "parse/2 returns nil for empty/whitespace output (unresolvable ⇒ skip, not rebuild)" do
    assert U.parse("", "master") == nil
    assert U.parse("\n", "master") == nil
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd orchestrator && mix test test/orchestrator/upstream_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Create the behaviour**

Create `orchestrator/lib/orchestrator/upstream.ex`:

```elixir
defmodule Orchestrator.Upstream do
  @moduledoc """
  IO behaviour: resolve a git ref in `emacsmirror/emacs` to its commit sha. The adapter
  MUST normalize an absent/unresolvable ref to `nil` (never raise) — `Core.Detect` maps
  `nil` → `{false, :no_upstream}` (a skip, never a rebuild).
  """
  @callback resolve(ref :: String.t()) :: String.t() | nil
end
```

- [ ] **Step 4: Create the adapter (pure `parse/2` + thin IO)**

Create `orchestrator/lib/orchestrator/upstream/git_ls_remote.ex`:

```elixir
defmodule Orchestrator.Upstream.GitLsRemote do
  @moduledoc "Default `Orchestrator.Upstream` — `git ls-remote https://github.com/emacsmirror/emacs <ref>`."
  @behaviour Orchestrator.Upstream
  @url "https://github.com/emacsmirror/emacs"

  @impl true
  def resolve(ref) do
    case System.cmd("git", ["ls-remote", @url, ref], stderr_to_stdout: true) do
      {out, 0} -> parse(out, ref)
      _ -> nil
    end
  end

  @doc "Pure: pick the sha for `ref` from ls-remote stdout (`<sha>\\t<refname>` lines); nil if none."
  @spec parse(String.t(), String.t()) :: String.t() | nil
  def parse(out, ref) do
    rows =
      out
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line, "\t", parts: 2) do
          [sha, name] -> [{String.trim(sha), name}]
          _ -> []
        end
      end)

    exact = Enum.find(rows, fn {_, n} -> n in ["refs/heads/#{ref}", "refs/tags/#{ref}"] end)

    case exact || List.first(rows) do
      {sha, _} -> sha
      nil -> nil
    end
  end
end
```

- [ ] **Step 5: Run the test**

Run: `cd orchestrator && mix test test/orchestrator/upstream_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add orchestrator/lib/orchestrator/upstream.ex orchestrator/lib/orchestrator/upstream/git_ls_remote.ex orchestrator/test/orchestrator/upstream_test.exs
git commit -m "feat(phase5): Upstream behaviour + GitLsRemote adapter (resolve ref→sha)"
```

---

## Task 5: `Orchestrator.Releases` behaviour + `Releases.Gh` adapter

**Files:**
- Create: `orchestrator/lib/orchestrator/releases.ex`
- Create: `orchestrator/lib/orchestrator/releases/gh.ex`
- Test: `orchestrator/test/orchestrator/releases_test.exs`

The network IO (find latest, download asset, self-heal scan) is thin and exercised by the throwaway E2E (Task 13); the unit test targets the pure `parse_manifest/1`.

- [ ] **Step 1: Write the failing test**

Create `orchestrator/test/orchestrator/releases_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd orchestrator && mix test test/orchestrator/releases_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Create the behaviour**

Create `orchestrator/lib/orchestrator/releases.ex`:

```elixir
defmodule Orchestrator.Releases do
  @moduledoc """
  IO behaviour: read the cross-run state — the `build-manifest.json` attached to the release
  marked `latest` (spec §7.2). Self-heals by scanning recent releases; returns `nil` when none
  carries one (→ `Core.Decide` treats every version as `:first_run`, the pristine-repo case).
  """
  @callback last_manifest(repo :: String.t()) :: map() | nil
end
```

- [ ] **Step 4: Create the adapter (pure `parse_manifest/1` + gh IO)**

Create `orchestrator/lib/orchestrator/releases/gh.ex`:

```elixir
defmodule Orchestrator.Releases.Gh do
  @moduledoc """
  Default `Orchestrator.Releases` — fetch `build-manifest.json` from the `latest` release via
  `gh`; if absent/corrupt, scan the most-recent releases (newest first). `nil` when none.
  """
  @behaviour Orchestrator.Releases
  @asset "build-manifest.json"
  @scan 10

  @impl true
  def last_manifest(repo) do
    [latest_tag(repo) | recent_tags(repo)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.find_value(&fetch(repo, &1))
  end

  defp latest_tag(repo) do
    case gh(["release", "view", "--repo", repo, "--json", "tagName", "--jq", ".tagName"]) do
      {out, 0} -> trim_nil(out)
      _ -> nil
    end
  end

  defp recent_tags(repo) do
    case gh(["release", "list", "--repo", repo, "--limit", "#{@scan}", "--json", "tagName", "--jq", ".[].tagName"]) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
      _ -> []
    end
  end

  defp fetch(repo, tag) do
    dir = Path.join(System.tmp_dir!(), "rel-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      case gh(["release", "download", tag, "--repo", repo, "--pattern", @asset, "--dir", dir]) do
        {_, 0} -> dir |> Path.join(@asset) |> File.read() |> parse_manifest()
        _ -> nil
      end
    after
      File.rm_rf!(dir)
    end
  end

  @doc "Pure: parse a `{:ok, json}`/`{:error, _}`/json string into a manifest map; nil otherwise."
  def parse_manifest({:ok, json}), do: parse_manifest(json)
  def parse_manifest({:error, _}), do: nil

  def parse_manifest(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, %{"versions" => _} = m} -> m
      _ -> nil
    end
  end

  defp trim_nil(s) do
    case String.trim(s) do
      "" -> nil
      t -> t
    end
  end

  defp gh(args), do: System.cmd("gh", args, stderr_to_stdout: true)
end
```

- [ ] **Step 5: Run the test**

Run: `cd orchestrator && mix test test/orchestrator/releases_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add orchestrator/lib/orchestrator/releases.ex orchestrator/lib/orchestrator/releases/gh.ex orchestrator/test/orchestrator/releases_test.exs
git commit -m "feat(phase5): Releases behaviour + Gh adapter (read latest build-manifest.json)"
```

---

## Task 6: `Manifest.versions!/1` + `Manifest.merge/2`

**Files:**
- Modify: `orchestrator/lib/orchestrator/manifest.ex` (add two functions)
- Modify: `orchestrator/test/orchestrator/manifest_test.exs` (add tests)

- [ ] **Step 1: Write the failing tests**

Append to `orchestrator/test/orchestrator/manifest_test.exs` (before the final `end`):

```elixir
  test "versions!/1 reads the [%{name,channel,ref}] list from versions.toml under root" do
    vs = Manifest.versions!(@fixtures)
    assert %{name: "master", channel: "master", ref: "master"} in vs
    assert Enum.any?(vs, &(&1.name == "emacs-30.2" and &1.channel == "30.2"))
  end

  test "merge/2 with nil prior starts from the fragments (first run)" do
    frag = %{"schema" => 1, "versions" => %{"master" => %{"released_tag" => "t1"}}}
    assert Manifest.merge(nil, [frag]) ==
             %{"schema" => 1, "versions" => %{"master" => %{"released_tag" => "t1"}}}
  end

  test "merge/2 adds new version entries to the prior, fragments winning" do
    prior = %{"schema" => 1, "versions" => %{
      "master" => %{"released_tag" => "old"},
      "emacs-30.2" => %{"released_tag" => "keep"}
    }}
    merged = Manifest.merge(prior, [%{"versions" => %{"master" => %{"released_tag" => "new"}}}])
    assert merged["versions"]["master"]["released_tag"] == "new"
    assert merged["versions"]["emacs-30.2"]["released_tag"] == "keep"
  end

  test "merge/2 with no fragments preserves the prior versions" do
    prior = %{"schema" => 1, "versions" => %{"master" => %{"released_tag" => "t"}}}
    assert Manifest.merge(prior, []) == prior
  end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd orchestrator && mix test test/orchestrator/manifest_test.exs`
Expected: FAIL — `versions!/1`/`merge/2` undefined.

- [ ] **Step 3: Add the functions**

In `orchestrator/lib/orchestrator/manifest.ex`, before the final `end`, add:

```elixir
  @doc """
  The `[%{name, channel, ref}]` version list (for `Core.Decide.plan/4`) parsed from
  `versions.toml` under `root`. Distinct from `jobs/2`, which crosses in targets.
  """
  @spec versions!(Path.t()) :: [%{name: String.t(), channel: String.t(), ref: String.t()}]
  def versions!(root) do
    {:ok, map} = Toml.decode(File.read!(Path.join(root, "versions.toml")))

    for {name, v} <- Map.get(map, "versions", %{}) do
      %{name: name, channel: v["channel"], ref: v["ref"]}
    end
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Merge per-cell single-version fragments into the prior `latest` manifest (spec §4.4).
  Fragment version entries win; `prior` nil ⇒ start empty (first run). Always schema 1.
  """
  @spec merge(map() | nil, [map()]) :: map()
  def merge(prior, fragments) do
    base = (prior && Map.get(prior, "versions", %{})) || %{}

    merged =
      Enum.reduce(fragments, base, fn frag, acc ->
        Map.merge(acc, Map.get(frag, "versions", %{}))
      end)

    %{"schema" => 1, "versions" => merged}
  end
```

- [ ] **Step 4: Run the test**

Run: `cd orchestrator && mix test test/orchestrator/manifest_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add orchestrator/lib/orchestrator/manifest.ex orchestrator/test/orchestrator/manifest_test.exs
git commit -m "feat(phase5): Manifest.versions!/1 + merge/2 (decide input + finalize merge)"
```

---

## Task 7: `Core.Decide.force/3` (the force_version path)

**Files:**
- Modify: `orchestrator/lib/orchestrator/core/decide.ex` (add `force/3`)
- Modify: `orchestrator/test/orchestrator/core/decide_test.exs` (add tests)

- [ ] **Step 1: Write the failing tests**

Append to `orchestrator/test/orchestrator/core/decide_test.exs` (before the final `end`):

```elixir
  test "force/3 builds only the named version with reason :forced" do
    versions = [
      %{name: "master", channel: "master", ref: "master"},
      %{name: "emacs-30.2", channel: "30.2", ref: "emacs-30.2"}
    ]

    plan = Decide.force(versions, "emacs-30.2", "2026-06-13")
    assert [%{name: "emacs-30.2", channel: "30.2", reason: :forced}] = plan.build
    assert [%{name: "master", reason: :not_forced}] = plan.skip
    assert plan.date == "2026-06-13"
  end

  test "force/3 raises for an unknown version" do
    assert_raise ArgumentError, fn -> Decide.force(@versions, "nope", "2026-06-13") end
  end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd orchestrator && mix test test/orchestrator/core/decide_test.exs`
Expected: FAIL — `force/3` undefined.

- [ ] **Step 3: Add `force/3`**

In `orchestrator/lib/orchestrator/core/decide.ex`, after `plan/4`, add:

```elixir
  @doc """
  Force a single version into `build` (reason `:forced`), bypassing detection — the
  `workflow_dispatch(force_version)` path (spec §4.2). Raises if the version is unknown.
  `state` is `%{}` (a forced build's cell resolves upstream itself).
  """
  @spec force([map()], String.t(), String.t()) :: Plan.t()
  def force(versions, version_name, date) do
    v =
      Enum.find(versions, &(&1.name == version_name)) ||
        raise ArgumentError, "force_version #{inspect(version_name)} not in versions.toml"

    %Plan{
      date: date,
      build: [%{name: v.name, channel: v.channel, reason: :forced, state: %{}}],
      skip: for(o <- versions, o.name != version_name, do: %{name: o.name, reason: :not_forced})
    }
  end
```

- [ ] **Step 4: Run the test**

Run: `cd orchestrator && mix test test/orchestrator/core/decide_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add orchestrator/lib/orchestrator/core/decide.ex orchestrator/test/orchestrator/core/decide_test.exs
git commit -m "feat(phase5): Core.Decide.force/3 (workflow_dispatch force_version)"
```

---

## Task 8: `Orchestrator.Orchestrate` (pure shaping) + `mix orchestrate.decide`

**Files:**
- Create: `orchestrator/lib/orchestrator/orchestrate.ex`
- Create: `orchestrator/lib/mix/tasks/orchestrate.decide.ex`
- Test: `orchestrator/test/orchestrator/orchestrate_test.exs`
- Test: `orchestrator/test/mix/tasks/orchestrate_decide_test.exs`

- [ ] **Step 1: Write the failing pure-shaping test**

Create `orchestrator/test/orchestrator/orchestrate_test.exs`:

```elixir
defmodule Orchestrator.OrchestrateTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Orchestrate

  @versions [%{name: "master", channel: "master", ref: "master"}]
  @jobs [%{name: "master", channel: "master", ref: "master", target: "macos-arm64", os: "macos", arch: "arm64", runner: "macos-26"}]

  test "detect: first run builds, any=true, dry_run=false" do
    states = %{"master" => %{upstream_sha: "a", inputs_hash: "h"}}
    out = Orchestrate.decide_outputs("detect", @versions, @jobs, states, nil, "2026-06-13", nil)
    assert out.any == true
    assert out.dry_run == false
    assert [%{name: "master", runner: "macos-26"}] = out.matrix["include"]
  end

  test "detect: unchanged => empty matrix, any=false (the gate)" do
    states = %{"master" => %{upstream_sha: "a", inputs_hash: "h"}}
    manifest = %{"versions" => %{"master" => %{"upstream_sha" => "a", "inputs_hash" => "h"}}}
    out = Orchestrate.decide_outputs("detect", @versions, @jobs, states, manifest, "2026-06-13", nil)
    assert out.matrix == %{"include" => []}
    assert out.any == false
  end

  test "force: only the named version, any=true, dry_run=false" do
    out = Orchestrate.decide_outputs("force", @versions, @jobs, %{}, nil, "2026-06-13", "master")
    assert [%{name: "master"}] = out.matrix["include"]
    assert out.any == true and out.dry_run == false
  end

  test "dry-run: all enabled jobs, dry_run=true" do
    out = Orchestrate.decide_outputs("dry-run", @versions, @jobs, %{}, nil, "2026-06-13", nil)
    assert [%{name: "master"}] = out.matrix["include"]
    assert out.dry_run == true
  end

  test "finalize_outputs merges fragments and picks the last built tag" do
    frag = %{"versions" => %{"master" => %{"released_tag" => "emacs-master-2026-06-13"}}}
    out = Orchestrate.finalize_outputs(nil, [frag], ["emacs-master-2026-06-13"])
    assert out.latest_tag == "emacs-master-2026-06-13"
    assert out.manifest["versions"]["master"]["released_tag"] == "emacs-master-2026-06-13"
  end

  test "finalize_outputs with no built tags => latest_tag nil (no flip)" do
    out = Orchestrate.finalize_outputs(nil, [], [])
    assert out.latest_tag == nil
    assert out.manifest == %{"schema" => 1, "versions" => %{}}
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd orchestrator && mix test test/orchestrator/orchestrate_test.exs`
Expected: FAIL — `Orchestrator.Orchestrate` undefined.

- [ ] **Step 3: Create the pure shaping module**

Create `orchestrator/lib/orchestrator/orchestrate.ex`:

```elixir
defmodule Orchestrator.Orchestrate do
  @moduledoc """
  Pure shaping for the decide/finalize jobs (spec §4.2/§4.4): wraps `Core.{Decide,Latest}` +
  `Manifest.merge` into the job-output / manifest shapes the workflow consumes. No IO — the
  mix tasks do the git/gh/clang IO and hand the gathered data here.
  """
  alias Orchestrator.Core.{Decide, Latest}
  alias Orchestrator.Core.Decide.Plan
  alias Orchestrator.Manifest

  @type outputs :: %{matrix: %{String.t() => [map()]}, any: boolean(), dry_run: boolean()}

  @doc "Shape the decide job outputs for a mode. `states`/`manifest` are used only in `detect`."
  @spec decide_outputs(String.t(), [map()], [map()], map(), map() | nil, String.t(), String.t() | nil) :: outputs()
  def decide_outputs(mode, versions, jobs, states, manifest, date, force_version) do
    plan =
      case mode do
        "detect" -> Decide.plan(versions, states, manifest, date)
        "force" -> Decide.force(versions, force_version, date)
        "dry-run" -> all(versions, date)
      end

    cells = Decide.matrix(plan, jobs)
    %{matrix: %{"include" => cells}, any: cells != [], dry_run: mode == "dry-run"}
  end

  defp all(versions, date) do
    %Plan{
      date: date,
      build: Enum.map(versions, &%{name: &1.name, channel: &1.channel, reason: :dry_run, state: %{}}),
      skip: []
    }
  end

  @doc "Merge fragments into prior + pick the latest tag (spec §4.4). `built_tags` oldest→newest."
  @spec finalize_outputs(map() | nil, [map()], [String.t()]) :: %{manifest: map(), latest_tag: String.t() | nil}
  def finalize_outputs(prior, fragments, built_tags) do
    latest =
      case Latest.latest_target(built_tags) do
        {:set, tag} -> tag
        :unchanged -> nil
      end

    %{manifest: Manifest.merge(prior, fragments), latest_tag: latest}
  end
end
```

- [ ] **Step 4: Run the pure test (PASS), then write the task test (failing)**

Run: `cd orchestrator && mix test test/orchestrator/orchestrate_test.exs` → PASS.

Create `orchestrator/test/mix/tasks/orchestrate_decide_test.exs`:

```elixir
defmodule Mix.Tasks.Orchestrate.DecideTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  @fixtures Path.expand("../../support/fixtures", __DIR__)

  test "dry-run mode emits matrix + any + dry_run (no IO, reads fixtures)" do
    out =
      capture_io(fn ->
        Mix.Task.rerun("orchestrate.decide", ["--mode", "dry-run", "--date", "2026-06-13", "--root", @fixtures])
      end)

    assert out =~ ~r/^matrix=\{"include":\[/m
    assert out =~ "any=true"
    assert out =~ "dry_run=true"
  end

  test "force mode emits only the forced version" do
    out =
      capture_io(fn ->
        Mix.Task.rerun("orchestrate.decide", ["--mode", "force", "--force-version", "master", "--date", "2026-06-13", "--root", @fixtures])
      end)

    assert out =~ ~s("name":"master")
    refute out =~ ~s("name":"emacs-30.2")
    assert out =~ "dry_run=false"
  end

  test "detect mode wires injected deps (no network) over a tmp root" do
    root = Path.join(System.tmp_dir!(), "decide-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "versions/master"))
    File.write!(Path.join(root, "mise.toml"), "# repo\n")
    File.write!(Path.join(root, "mise.lock"), "# lock\n")
    File.cp!(Path.join(@fixtures, "versions.toml"), Path.join(root, "versions.toml"))
    File.cp!(Path.join(@fixtures, "targets.toml"), Path.join(root, "targets.toml"))
    for f <- ~w(mise.toml pixi.toml pixi.lock), do: File.write!(Path.join(root, "versions/master/#{f}"), "# #{f}\n")
    # versions.toml fixture also has emacs-30.2; give it input files too
    File.mkdir_p!(Path.join(root, "versions/emacs-30.2"))
    for f <- ~w(mise.toml pixi.toml pixi.lock), do: File.write!(Path.join(root, "versions/emacs-30.2/#{f}"), "# #{f}\n")
    on_exit(fn -> File.rm_rf!(root) end)

    deps = %{
      upstream: fn _ref -> "sha-x" end,
      releases: fn _repo -> nil end,
      toolchain: fn -> "sha256:cltfix" end
    }

    out = Mix.Tasks.Orchestrate.Decide.exec(%{mode: "detect", date: "2026-06-13", repo: "o/r", root: root}, deps)
    assert out.any == true
    assert out.dry_run == false
    assert Enum.any?(out.matrix["include"], &(&1.name == "master"))
  end
end
```

- [ ] **Step 5: Run it to confirm it fails**

Run: `cd orchestrator && mix test test/mix/tasks/orchestrate_decide_test.exs`
Expected: FAIL — task `orchestrate.decide` not found.

- [ ] **Step 6: Create the decide task**

Create `orchestrator/lib/mix/tasks/orchestrate.decide.ex`:

```elixir
defmodule Mix.Tasks.Orchestrate.Decide do
  @shortdoc "Emit the dynamic build matrix + gate flags (spec §4.2)"
  @moduledoc """
  The decide-gate brain. Modes: `detect` (compare upstream+inputs vs the latest manifest),
  `force` (one ref), `dry-run` (all enabled, PR). Prints `key=value` lines (matrix JSON, any,
  dry_run) for `>> "$GITHUB_OUTPUT"`. IO (git ls-remote / gh / clang) is gathered here and
  handed to the pure `Orchestrator.Orchestrate`.

      mix orchestrate.decide --repo <owner/repo> --date 2026-06-13 --mode detect [--root ..]
      mix orchestrate.decide --mode force --force-version master --date <d>
      mix orchestrate.decide --mode dry-run --date <d>
  """
  use Mix.Task
  alias Orchestrator.{Manifest, Orchestrate, Core.Hash}

  @switches [repo: :string, date: :string, mode: :string, force_version: :string, root: :string]

  @impl true
  def run(argv) do
    {opts, [], []} = OptionParser.parse(argv, strict: @switches)
    opts |> Map.new() |> main(default_deps())
  end

  @doc "exec + emit; `deps` injectable for tests."
  def main(opts, deps) do
    out = exec(opts, deps)
    emit(out)
    out
  end

  @doc "Gather IO (detect only) + shape outputs."
  def exec(opts, deps \\ default_deps()) do
    root = opts[:root] || ".."
    date = fetch!(opts, :date)
    mode = fetch!(opts, :mode)
    versions = Manifest.versions!(root)
    {:ok, jobs} = Manifest.load(Path.join(root, "versions.toml"), Path.join(root, "targets.toml"))

    {states, manifest} =
      if mode == "detect" do
        clt = deps.toolchain.()
        {current_states(versions, root, clt, deps.upstream), deps.releases.(fetch!(opts, :repo))}
      else
        {%{}, nil}
      end

    Orchestrate.decide_outputs(mode, versions, jobs, states, manifest, date, opts[:force_version])
  end

  defp current_states(versions, root, clt, resolve) do
    toolchain_hash =
      Hash.toolchain_hash(
        File.read!(Path.join(root, "mise.toml")),
        File.read!(Path.join(root, "mise.lock")),
        clt
      )

    for v <- versions, into: %{} do
      [mise_toml, pixi_toml, pixi_lock] =
        v.name |> Manifest.version_input_files() |> Enum.map(&File.read!(Path.join(root, &1)))

      sha = resolve.(v.ref)

      hash =
        Hash.version_fingerprint(%{
          toolchain_hash: toolchain_hash,
          upstream_sha: sha || "",
          mise_toml: mise_toml,
          pixi_toml: pixi_toml,
          pixi_lock: pixi_lock
        })

      {v.name, %{upstream_sha: sha, inputs_hash: hash}}
    end
  end

  defp emit(%{matrix: matrix, any: any, dry_run: dry_run}) do
    IO.puts("matrix=#{JSON.encode!(matrix)}")
    IO.puts("any=#{any}")
    IO.puts("dry_run=#{dry_run}")
  end

  def default_deps do
    %{
      upstream: &Orchestrator.Upstream.GitLsRemote.resolve/1,
      releases: &Orchestrator.Releases.Gh.last_manifest/1,
      toolchain: &Orchestrator.Toolchain.Macos.clt_fingerprint/0
    }
  end

  defp fetch!(opts, key),
    do: opts[key] || Mix.raise("missing --#{key |> Atom.to_string() |> String.replace("_", "-")}")
end
```

- [ ] **Step 7: Run both test files**

Run: `cd orchestrator && mix test test/orchestrator/orchestrate_test.exs test/mix/tasks/orchestrate_decide_test.exs`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add orchestrator/lib/orchestrator/orchestrate.ex orchestrator/lib/mix/tasks/orchestrate.decide.ex orchestrator/test/orchestrator/orchestrate_test.exs orchestrator/test/mix/tasks/orchestrate_decide_test.exs
git commit -m "feat(phase5): Orchestrate.decide_outputs + mix orchestrate.decide (gate brain)"
```

---

## Task 9: `mix orchestrate.finalize` (merge fragments + pick latest)

**Files:**
- Create: `orchestrator/lib/mix/tasks/orchestrate.finalize.ex`
- Test: `orchestrator/test/mix/tasks/orchestrate_finalize_test.exs`

- [ ] **Step 1: Write the failing test**

Create `orchestrator/test/mix/tasks/orchestrate_finalize_test.exs`:

```elixir
defmodule Mix.Tasks.Orchestrate.FinalizeTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    dir = Path.join(System.tmp_dir!(), "frags-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, out: Path.join(dir, "build-manifest.json")}
  end

  test "merges fragments into nil prior, writes manifest, prints latest_tag", %{dir: dir, out: out} do
    File.write!(Path.join(dir, "manifest-master.json"),
      ~s({"schema":1,"versions":{"master":{"released_tag":"emacs-master-2026-06-13","inputs_hash":"h"}}}))

    printed =
      capture_io(fn ->
        Mix.Tasks.Orchestrate.Finalize.main(
          %{repo: "o/r", fragments: dir, out: out},
          %{releases: fn _ -> nil end}
        )
      end)

    assert printed =~ "latest_tag=emacs-master-2026-06-13"
    written = out |> File.read!() |> JSON.decode!()
    assert written["versions"]["master"]["inputs_hash"] == "h"
  end

  test "zero fragments => latest_tag= (empty, no flip)", %{dir: dir, out: out} do
    printed =
      capture_io(fn ->
        Mix.Tasks.Orchestrate.Finalize.main(%{repo: "o/r", fragments: dir, out: out}, %{releases: fn _ -> nil end})
      end)

    assert printed =~ ~r/^latest_tag=\s*$/m
  end

  test "merges a fragment on top of a prior manifest from Releases", %{dir: dir, out: out} do
    File.write!(Path.join(dir, "manifest-master.json"),
      ~s({"versions":{"master":{"released_tag":"new"}}}))

    prior = %{"schema" => 1, "versions" => %{"emacs-30.2" => %{"released_tag" => "keep"}}}

    capture_io(fn ->
      Mix.Tasks.Orchestrate.Finalize.main(%{repo: "o/r", fragments: dir, out: out}, %{releases: fn _ -> prior end})
    end)

    written = out |> File.read!() |> JSON.decode!()
    assert written["versions"]["master"]["released_tag"] == "new"
    assert written["versions"]["emacs-30.2"]["released_tag"] == "keep"
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd orchestrator && mix test test/mix/tasks/orchestrate_finalize_test.exs`
Expected: FAIL — task undefined.

- [ ] **Step 3: Create the finalize task**

Create `orchestrator/lib/mix/tasks/orchestrate.finalize.ex`:

```elixir
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
```

- [ ] **Step 4: Run the test**

Run: `cd orchestrator && mix test test/mix/tasks/orchestrate_finalize_test.exs`
Expected: PASS.

- [ ] **Step 5: Full suite + warnings gate**

Run: `mise run test`
Expected: PASS, no warnings.

- [ ] **Step 6: Commit**

```bash
git add orchestrator/lib/mix/tasks/orchestrate.finalize.ex orchestrator/test/mix/tasks/orchestrate_finalize_test.exs
git commit -m "feat(phase5): mix orchestrate.finalize (merge fragments + select latest tag)"
```

---

## Task 10: bash — `publish` writes the tag; `promote` accepts `--manifest`

**Files:**
- Modify: `pipeline/publish` (success branch: write `dist/<v>/published-tag.txt`)
- Modify: `pipeline/promote` (add `--manifest <path>`; skip local-dist checks when given)

Bash isn't ExUnit-tested; validation = `shellcheck` here + the throwaway E2E (Task 13). These edits respect the bash-3.2 traps already encoded in those scripts (KB bash.md).

- [ ] **Step 1: `publish` — record the resolved tag**

In `pipeline/publish`, in the `rc -eq 0` success branch, add the tag-file write before `exit 0`. The branch becomes:

```bash
  if [ $rc -eq 0 ]; then
    echo "$err"
    printf '%s\n' "$TAG" > "$HERE/dist/$VERSION/published-tag.txt"
    echo ">> publish: PASS — $TAG on $REPO (not latest; promote is a separate step)"
    exit 0
```

- [ ] **Step 2: `promote` — accept a pre-built merged manifest**

In `pipeline/promote`, add `MANIFEST=""` to the var inits and a `--manifest` case to the arg loop:

```bash
REPO=""; TAG=""; VERSION="master"; MANIFEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     REPO="${2:?}"; shift 2 ;;
    --tag)      TAG="${2:?}"; shift 2 ;;
    --version)  VERSION="${2:?}"; shift 2 ;;
    --manifest) MANIFEST="${2:?}"; shift 2 ;;
    *) echo "FATAL: unknown arg $1"; exit 1 ;;
  esac
done
```

Then replace everything from the `SHA_FILE=...` line through the `mix release.manifest` block (steps that build the single-version manifest from local `dist/`) with a branch that uses `$MANIFEST` directly when provided. The body after the G8 interlock becomes:

```bash
if [ -n "$MANIFEST" ]; then
  # Phase-5 finalize path: caller supplies the merged manifest; the release + assets already
  # exist on GitHub (published by the build cell — possibly a different runner), so NO local
  # dist/ lookups (no SHA_FILE, no asset existence check).
  [ -f "$MANIFEST" ] || { echo "FATAL: --manifest $MANIFEST not found"; exit 1; }
  MANIFEST_PATH="$MANIFEST"
else
  # Phase-4 local path: compute the single-version manifest from dist/<version>/.
  SHA_FILE="$HERE/dist/$VERSION/upstream-sha.txt"
  [ -f "$SHA_FILE" ] || { echo "FATAL: $SHA_FILE missing — run pipeline/package (or publish) first"; exit 1; }

  ASSET=""
  while IFS= read -r line; do
    case "$line" in asset=*) ASSET="${line#asset=}" ;; esac
  done < <(cd "$HERE/orchestrator" && mise exec -- mix release.names --tag "$TAG" --os macos --arch arm64)
  [ -n "$ASSET" ] && [ -f "$HERE/dist/$VERSION/$ASSET" ] || {
    echo "FATAL: $HERE/dist/$VERSION/$ASSET missing — does --tag match the packaged dist/ artifact?"; exit 1; }

  echo ">> [1] build-manifest.json via mix release.manifest (Core.Hash fingerprint)"
  (cd "$HERE/orchestrator" && mise exec -- mix release.manifest \
    --version "$VERSION" --tag "$TAG" --upstream-sha "$(cat "$SHA_FILE")" \
    --root "$HERE" --out "$HERE/dist/$VERSION/build-manifest.json")
  MANIFEST_PATH="$HERE/dist/$VERSION/build-manifest.json"
fi

echo ">> [2] attach manifest (idempotent)"
gh release upload "$TAG" "$MANIFEST_PATH" --repo "$REPO" --clobber

echo ">> [3] flip Latest marker to $TAG"
gh release edit "$TAG" --repo "$REPO" --latest

echo ">> promote: PASS — $TAG is Latest on $REPO and carries build-manifest.json"
```

(Delete the old `SHA_FILE=...`/`ASSET=...`/`[1]`/`[2]`/`[3]` lines this block replaces — they are now inside the `else`/shared tail above.)

- [ ] **Step 3: Lint both scripts**

Run: `shellcheck pipeline/publish pipeline/promote`
Expected: no errors (warnings consistent with the rest of the repo are fine).

- [ ] **Step 4: Smoke `promote --manifest` arg-parsing locally (no network)**

Run:
```bash
printf '{"schema":1,"versions":{}}' > /tmp/m.json
bash pipeline/promote --repo o/r --tag t --manifest /tmp/missing.json 2>&1 | head -1   # expect: FATAL --manifest ... not found
```
Expected: the `--manifest ... not found` FATAL (proves the new branch + arg parse; no gh call reached).

- [ ] **Step 5: Commit**

```bash
git add pipeline/publish pipeline/promote
git commit -m "feat(phase5): publish writes published-tag.txt; promote --manifest (finalize path)"
```

---

## Task 11: mise tasks `decide` + `finalize`

**Files:**
- Modify: `mise.toml` (append two tasks)

- [ ] **Step 1: Append the tasks**

Add to `mise.toml`:

```toml
[tasks.decide]
description = "Phase 5: emit the dynamic build matrix + gate flags; args: --repo <owner/repo> --date <YYYY-MM-DD> --mode <detect|force|dry-run> [--force-version <name>]"
dir = "orchestrator"
run = "mix orchestrate.decide"

[tasks.finalize]
description = "Phase 5: merge per-cell manifest fragments + pick latest; args: --repo <owner/repo> --fragments <dir> --out <path>"
dir = "orchestrator"
run = "mix orchestrate.finalize"
```

- [ ] **Step 2: Smoke `decide` in dry-run mode locally (no network — reads repo manifests)**

Run: `mise run decide -- --mode dry-run --date 2026-06-13`
Expected: three lines — `matrix={"include":[{...,"name":"master",...,"runner":"macos-26",...}]}`, `any=true`, `dry_run=true`. (dir=orchestrator ⇒ `--root` defaults to `..` = repo root; reads the real `versions.toml`/`targets.toml`.)

- [ ] **Step 3: Commit**

```bash
git add mise.toml
git commit -m "feat(phase5): mise tasks decide + finalize (one-definition seam)"
```

---

## Task 12: `.github/workflows/daily.yml` (decide → build → finalize)

**Files:**
- Create: `.github/workflows/daily.yml`

Local check = `actionlint` (a GHA linter; install via `mise x aqua:rhysd/actionlint -- actionlint` or skip if unavailable) + YAML parse. Real validation = the throwaway repo (Task 13). The cron `schedule` ships in the file but only fires once this lands on a default branch (A10).

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/daily.yml`:

```yaml
name: daily
on:
  schedule:
    - cron: '0 7 * * *'        # daily; activated by the cutover push to main (A10)
  workflow_dispatch:
    inputs:
      force_version:
        description: 'Build exactly this version (bypass detect); blank = run detect now'
        type: string
        required: false
  pull_request:
    paths: ['versions/**', '**/*.toml']

permissions:
  contents: read

# No workflow-level concurrency: serialization is per-job (build-<name>-<target> +
# finalize-latest), so distinct cells run in parallel and only same-cell / latest collide.

jobs:
  decide:
    runs-on: macos-26
    outputs:
      matrix: ${{ steps.decide.outputs.matrix }}
      any: ${{ steps.decide.outputs.any }}
      dry_run: ${{ steps.decide.outputs.dry_run }}
    env:
      GH_TOKEN: ${{ github.token }}
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v2
      - id: decide
        run: |
          set -euo pipefail
          EVENT="${{ github.event_name }}"
          FORCE="${{ inputs.force_version }}"
          if   [ "$EVENT" = "pull_request" ]; then set -- --mode dry-run
          elif [ "$EVENT" = "workflow_dispatch" ] && [ -n "$FORCE" ]; then set -- --mode force --force-version "$FORCE"
          else set -- --mode detect; fi
          mise run decide -- --repo "${{ github.repository }}" --date "$(date -u +%F)" "$@" \
            | tee -a "$GITHUB_OUTPUT" "$GITHUB_STEP_SUMMARY"

  build:
    needs: decide
    if: needs.decide.outputs.any == 'true'
    runs-on: ${{ matrix.runner }}
    permissions:
      contents: write
    strategy:
      fail-fast: false
      matrix: ${{ fromJSON(needs.decide.outputs.matrix) }}
    concurrency:
      group: build-${{ matrix.name }}-${{ matrix.target }}
      cancel-in-progress: false
    env:
      GH_TOKEN: ${{ github.token }}
      MISEMACS_PUBLISH_OK: ${{ github.repository == 'djgoku/misemacs' && '1' || '' }}
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v2
      - name: pixi-env cache
        uses: actions/cache@v4
        with:
          path: versions/${{ matrix.name }}/.pixi
          key: pixi-${{ matrix.target }}-${{ hashFiles(format('versions/{0}/pixi.lock', matrix.name)) }}
      - name: build + relocate
        run: |
          set -euo pipefail
          mise run build "${{ matrix.name }}"
          mise run relocate
      - name: publish (real) or package+artifact (dry-run)
        run: |
          set -euo pipefail
          if [ "${{ needs.decide.outputs.dry_run }}" = "true" ]; then
            TAG="$(cd orchestrator && mise exec -- mix release.names \
              --channel '${{ matrix.channel }}' --date "$(date -u +%F)" \
              --os '${{ matrix.os }}' --arch '${{ matrix.arch }}' --tags-file /dev/null \
              | sed -n 's/^tag=//p')"
            mise run package "${{ matrix.name }}" "$TAG"
          else
            mise run publish -- --repo "${{ github.repository }}" --version "${{ matrix.name }}"
          fi
      - name: manifest fragment (real only)
        if: needs.decide.outputs.dry_run != 'true'
        run: |
          set -euo pipefail
          TAG="$(cat dist/${{ matrix.name }}/published-tag.txt)"
          SHA="$(cat dist/${{ matrix.name }}/upstream-sha.txt)"
          (cd orchestrator && mise exec -- mix release.manifest \
            --version "${{ matrix.name }}" --tag "$TAG" --upstream-sha "$SHA" \
            --root .. --out "../dist/${{ matrix.name }}/build-manifest.json")
      - name: upload fragment (real) / tarball (dry-run)
        uses: actions/upload-artifact@v4
        with:
          name: ${{ needs.decide.outputs.dry_run == 'true' && format('dryrun-{0}-{1}', matrix.name, matrix.target) || format('manifest-{0}-{1}', matrix.name, matrix.target) }}
          path: ${{ needs.decide.outputs.dry_run == 'true' && format('dist/{0}/*.tar.gz', matrix.name) || format('dist/{0}/build-manifest.json', matrix.name) }}
          if-no-files-found: error

  finalize:
    needs: [decide, build]
    if: ${{ !cancelled() && needs.decide.outputs.dry_run != 'true' && needs.decide.outputs.any == 'true' }}
    runs-on: ubuntu-latest
    permissions:
      contents: write
    concurrency:
      group: finalize-latest
      cancel-in-progress: false
    env:
      GH_TOKEN: ${{ github.token }}
      MISEMACS_PUBLISH_OK: ${{ github.repository == 'djgoku/misemacs' && '1' || '' }}
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v2
      - uses: actions/download-artifact@v4
        with:
          path: fragments
          pattern: manifest-*
      - name: finalize (merge + attach + flip)
        run: |
          set -euo pipefail
          LATEST_TAG="$(mise run finalize -- \
            --repo "${{ github.repository }}" \
            --fragments "$GITHUB_WORKSPACE/fragments" \
            --out "$GITHUB_WORKSPACE/dist/build-manifest.json" \
            | sed -n 's/^latest_tag=//p')"
          if [ -z "$LATEST_TAG" ]; then echo "nothing to finalize (no fragments)"; exit 0; fi
          bash pipeline/promote --repo "${{ github.repository }}" --tag "$LATEST_TAG" \
            --manifest "$GITHUB_WORKSPACE/dist/build-manifest.json"
```

- [ ] **Step 2: Lint the workflow**

Run: `mise x aqua:rhysd/actionlint -- actionlint .github/workflows/daily.yml` (or `actionlint` if installed; if unavailable, at least `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/daily.yml'))"` to confirm it parses).
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/daily.yml
git commit -m "feat(phase5): daily.yml — decide(macos-26)→build(matrix)→finalize"
```

> **Optional sub-task (ccache, T7 — defer if it complicates the build):** add a ccache `actions/cache` step (key `ccache-${{ matrix.target }}-${{ hashFiles(format('versions/{0}/pixi.lock', matrix.name)) }}-${{ github.sha }}`, restore-keys the same prefix then `ccache-${{ matrix.target }}-`), set `CCACHE_DIR=~/.cache/ccache`, and wire the compile through it (e.g. `CC='ccache clang'` in `pipeline/build-emacs`'s `./configure`). Validate a warm-cache speedup on the throwaway. ccache is an optimization only — native-comp is off, so the build is correct without it; skip if it fights the dump step.

---

## Task 13: Throwaway-repo validation (the whole DoD — T1–T10)

**Operational, not TDD.** This is where Phase 5 is *finished* (spec §5/A10). `djgoku/misemacs` is never touched. The "Phase-5 branch" = the worktree branch carrying Tasks 1–12. Record every result (run URLs, outputs) into `docs/superpowers/validation-log.md` as you go (folds into Task 14).

- [ ] **Step 1: Create the lab repo + push the branch (token-HTTPS, no signing)**

```bash
LAB=djgoku/misemacs-phase5-lab
gh repo create "$LAB" --public --description "Phase 5 throwaway (delete after cutover)"
git remote add lab "https://x-access-token:$(gh auth token)@github.com/$LAB.git"
git push lab HEAD:main          # HEAD = the Phase-5 worktree branch
```
Expected: repo created; branch on `lab` `main`.

- [ ] **Step 2: Swap the lab's `aqua/registry.yaml` repo-name → the lab (so `aqua:$LAB@<tag>` resolves)**

Edit only the lab's copy (NOT the branch — the branch keeps `repo_name: misemacs` for the real cutover). Fetch, sed `repo_name`, PUT back via the contents API:
```bash
SHA=$(gh api repos/$LAB/contents/aqua/registry.yaml --jq .sha)
gh api repos/$LAB/contents/aqua/registry.yaml --jq '.content' | base64 -d \
  | sed 's/repo_name: misemacs/repo_name: misemacs-phase5-lab/' | base64 > /tmp/reg.b64
gh api -X PUT repos/$LAB/contents/aqua/registry.yaml -f message="lab: swap repo_name" \
  -f content="$(cat /tmp/reg.b64)" -f sha="$SHA" >/dev/null
```
Expected: lab registry points at the lab. (Re-push of the branch later would overwrite this — re-run if so.)

- [ ] **Step 3 (T6, T1, T2, T10): first `workflow_dispatch` = first_run → build → finalize**

```bash
gh workflow run daily.yml --repo "$LAB"
gh run watch --repo "$LAB" "$(gh run list --repo "$LAB" --workflow daily.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```
Expected: `decide` schedules on **macos-26** (T6: no "image not found"); emits a non-empty `matrix` consumed by `build` (T1/T2); `build` publishes `emacs-master-<date>` `--latest=false` + uploads a `manifest-*` fragment; `finalize` merges (nil prior → first manifest), prints `latest_tag`, `promote --manifest` attaches + flips. Verify:
```bash
gh release view --repo "$LAB" --json tagName,isLatest,assets --jq '{tag:.tagName,latest:.isLatest,assets:[.assets[].name]}'
```
Expected: the dated tag is Latest with `…tar.gz`, `SHASUMS256.txt`, `build-manifest.json` (T10).

- [ ] **Step 4 (T9 idempotency): a second same-day dispatch releases nothing**

```bash
gh workflow run daily.yml --repo "$LAB"; sleep 5
# watch the new run
```
Expected: `decide` reads the now-present manifest → master unchanged → `any=false` → `build` and `finalize` **skipped**; release count unchanged. (The §14 DoD.)

- [ ] **Step 5 (T8 dry-run): a PR touching `versions/**` builds an artifact, no release**

```bash
git push lab HEAD:pr-smoke   # a branch
gh pr create --repo "$LAB" --base main --head pr-smoke --title "dry-run smoke" --body "touch versions" 
# (first make a trivial edit under versions/** on pr-smoke so the paths filter matches)
```
Expected: the workflow runs `decide --mode dry-run`; `build` packages + uploads a `dryrun-*` tarball artifact; **no** new release; `finalize` skipped (`dry_run=true`).

- [ ] **Step 6 (T8 force): `workflow_dispatch(force_version=master)` force-builds one ref**

```bash
gh workflow run daily.yml --repo "$LAB" -f force_version=master
```
Expected: `decide --mode force` → matrix = master only (reason forced); a new release `emacs-master-<date>.1` (same-day `.N`); finalize flips it Latest.

- [ ] **Step 7 (T3 concurrency): two overlapping dispatches**

```bash
gh workflow run daily.yml --repo "$LAB" -f force_version=master
gh workflow run daily.yml --repo "$LAB" -f force_version=master
```
Expected: the per-cell `build-master-macos-arm64` group serializes the two build cells (one queues) and `finalize-latest` serializes the two finalizes — no double-publish of the same tag (the second `.N`-bumps), no torn Latest flip.

- [ ] **Step 8 (T4 schedule-from-default): observe one cron tick**

Temporarily set the lab workflow's cron a few minutes out (edit `daily.yml` on lab `main`, e.g. `cron: '<next> * * *'`), wait for the scheduled run to appear, confirm it ran from `main` HEAD, then revert the cron.
Expected: a `schedule`-triggered run appears and executes the same `detect` path. (Confirms cron-last is the activation by construction.)

- [ ] **Step 9 (T5 fragments / T7 caches): confirm aggregation + cache hits**

In the Step-3/6 run logs: the `manifest-*` artifact uploaded by `build` is downloaded by `finalize` (T5); a second run shows the `pixi-env` cache restored (T7). Record both.

- [ ] **Step 10 (the §14 consumer check): clean-VM install of the lab's first release**

Reuse the Phase-4 clean-box path inside a fresh pregate VM (the existing `scripts/e2e-aqua-install.sh` / `mise run e2e`) with the lab registry URL:
```bash
mise run e2e "$LAB" "<the kept dated tag>" "https://raw.githubusercontent.com/$LAB/main/aqua/registry.yaml"
```
Expected (in-guest): `E2E-BATCH-OK <ver>`, `E2E-GUI-OK`, `E2E-EMBEDDED-SIGS-OK`, `E2E-NO-QUARANTINE`, `e2e: PASS`. This proves `mise use aqua:$LAB@<tag>` end-to-end.

- [ ] **Step 11: Record results, then commit the validation-log additions**

```bash
git add docs/superpowers/validation-log.md
git commit -m "docs(phase5): throwaway validation — T1–T10 results (lab)"
```

---

## Task 14: Docs reconcile

**Files:**
- Modify: `docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md` (§8, §11.2, §13, §14)
- Modify: `docs/superpowers/validation-log.md` (Phase-5 section — started in Task 13)
- Modify: auto-memory `project-bundled-emacs-buildsystem.md` (correct the stale state)
- (KB `github-actions.md` macos-26 fact already added this session.)

- [ ] **Step 1: Umbrella §8 — Decision E wired**

Change the "wired Phase 5" note to past tense: CLT/SDK folded into `toolchain_hash/3` via `Orchestrator.Toolchain.Macos`, captured identically by `decide` and `release.manifest` (both on `macos-26`).

- [ ] **Step 2: Umbrella §11.2 — decide on macos-26**

Note `decide` runs on **`macos-26`** (not ubuntu) so it computes the same CLT-inclusive fingerprint the build records (A1 rationale: free public Actions; avoids the cross-OS rebuild storm).

- [ ] **Step 3: Umbrella §13/§14 — Phase 5 done**

Move the GHA mechanics to "proved on the throwaway (T1–T10, run links)"; mark the §14 Phase-5 row done; note the real repo's first kept release lands at the cutover go-live.

- [ ] **Step 4: Auto-memory — correct the stale state**

In `~/.claude/projects/-Users-dj-goku-dev-github-djgoku-misemacs/memory/project-bundled-emacs-buildsystem.md`: cutover done (remote `main` = fresh take), repo pristine (0 releases/0 tags), public; `macos-26` adopted; Phase 5 status. (Supersedes the Phase-4 "no remote / legacy releases coexist" lines.)

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md docs/superpowers/validation-log.md
git commit -m "docs(phase5): reconcile umbrella spec §8/§11/§13/§14 + validation log"
```

---

## Task 15: Cutover to `djgoku/misemacs` (USER push)

**Operational. The real repo is touched exactly once, by the user (signed push). No testing has landed on it.**

- [ ] **Step 1: Pre-cutover sanity (Claude)**

Confirm on the Phase-5 branch: `targets.toml` runner = `macos-26`; `aqua/registry.yaml` `repo_name: misemacs` (NOT the lab — the branch must carry the real name); `mise run test` green; `git status` clean.
```bash
grep -n 'repo_name' aqua/registry.yaml         # expect: misemacs
grep -n 'runner' targets.toml                  # expect: macos-26
mise run test
```

- [ ] **Step 2: USER pushes the proven branch to `main`**

> **User action** (signed). Either fast-forward `main` to the branch, or merge it, then push:
```bash
git push origin <phase-5-branch>:main          # or a merge + push
```
Because `schedule` fires from `main` HEAD, this push **activates the cron** (A10).

- [ ] **Step 3 (T10 production go-live): first real run**

The first scheduled tick (or a confirming manual dispatch) is the repo's first kept release:
```bash
gh workflow run daily.yml --repo djgoku/misemacs        # optional confirming dispatch
gh release view --repo djgoku/misemacs --json tagName,isLatest --jq '{tag:.tagName,latest:.isLatest}'
```
Expected: `emacs-master-<date>` published `--latest=false` then flipped Latest by finalize; carries `build-manifest.json` (the first kept release + first manifest + first flip). A pristine-VM `mise use aqua:djgoku/misemacs@<tag>` confirms the real consumer path.

- [ ] **Step 4: USER deletes the throwaway**

> **User action** (token lacks `delete_repo`): delete `djgoku/misemacs-phase5-lab`. Remove the local `lab` remote: `git remote remove lab`.

---

## Self-Review (completed during authoring)

**Spec coverage:** §4.1 daily.yml → Task 12; §4.2 decide → Tasks 7,8; §4.3 build/dry-run → Task 12; §4.4 finalize → Tasks 6,9,10,12; §4.5 Decision E → Tasks 2,3; §4.6 caches → Task 12 (+ optional ccache); §4.7 surfaces → Tasks 2–11; §4.8 permissions/fork-safety → Task 12; §5 sequencing/A10 → Tasks 13,15; §7 docs → Task 14. No spec section is unimplemented.

**Type/name consistency:** `toolchain_hash/3` (Tasks 2,3,8); `decide_outputs/7` + `finalize_outputs/3` (Tasks 8,9); `Manifest.versions!/1` + `merge/2` (Tasks 6,8,9); `Decide.force/3` (Tasks 7,8); `main/2`+`exec/2` task seam (Tasks 8,9, tests); fragment artifact name `manifest-<name>-<target>` produced (Task 12 build) and consumed (`pattern: manifest-*`, Task 12 finalize); `published-tag.txt` written (Task 10 publish) and read (Task 12 build); `promote --manifest` added (Task 10) and used (Task 12 finalize). Consistent.

**Placeholder scan:** no TBD/TODO; every code step shows complete code; the one optional item (ccache) is explicitly optional with full key/wiring, not a placeholder.

---

## Execution Handoff

This plan is **uncommitted** until the spec-validation gate clears (see the chat). Once committed, two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, two-stage review between tasks (the Phase-4 approach, which worked well). REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Start by creating an isolated worktree (superpowers:using-git-worktrees) so Tasks 1–12 land on a Phase-5 branch, not `main`.

**2. Inline Execution** — execute tasks in this session with checkpoints. REQUIRED SUB-SKILL: superpowers:executing-plans.

Tasks 1–12 are TDD code (subagent-friendly); Tasks 13/15 are operational gates with real GitHub/VM IO (human-in-the-loop); Task 14 is docs.
