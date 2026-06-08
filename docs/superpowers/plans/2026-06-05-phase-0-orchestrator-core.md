# Phase 0 — Orchestrator Core & Contracts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the free, fully unit-testable foundation of the bundled-Emacs release system — the pure decision logic (change detection, fingerprinting, tag computation, release planning, matrix join, "latest") and the name/asset contract — with zero infrastructure cost, plus a dev-CI gate and a one-off validation of the mise pixi-plugin path.

**Architecture:** A standard Elixir mix project (`orchestrator/`) holding **pure functions only** (no IO): `Orchestrator.Naming` (sole owner of tag/asset name strings, pinned to the aqua registry contract), `Orchestrator.Core.{Hash,Detect,Tag,Decide,Latest}` (the release brain — including the `Decide.matrix/2` join that feeds the Phase-5 CI matrix), and `Orchestrator.Manifest` (the versions × targets cross-product that makes "add a version = data"). Every behavior is proven by ExUnit fixtures — no real builds, releases, or network. A dev-CI workflow re-proves it on every PR; a final non-code task validates the `mise` pixi plugins so Phase 1 starts on solid ground.

**Tech Stack:** Elixir 1.20.0 / OTP 29, ExUnit, `:crypto` (stdlib, sha256), `{:toml, "~> 0.7"}` (manifest parsing). Spec: `docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md`.

**This is the Phase 0 plan only.** Phases 1–6 each get their own plan when reached. Work happens on a branch off `main`; merge back when Phase 0 lands.

**Reviewed** by the design panel (architect, Elixir, process/CI, tooling); their BLOCKER/SHOULD-FIX feedback is incorporated below.

---

## Cross-phase contracts frozen here (read first)

These are the load-bearing invariants Phase 0 exists to pin down. Later phases depend on them:

1. **Fingerprint inputs are ORDERED + NAMED** (`Core.Hash`): `[:toolchain_hash, :upstream_sha, :mise_toml, :pixi_toml, :pixi_lock]`, in that order (spec §8). A caller cannot reorder/drop a field without failing a Phase-0 test. `toolchain_hash` = `sha256(repo mise.toml ⧺ mise.lock)`.
2. **`job.name` is the universal join key** == the `versions/<name>/` directory == the key in `current_states` and the `build-manifest.json` `"versions"` map. Keep table key == git ref where practical (`[versions."emacs-30.2"]`), `channel` is the short form.
3. **Name strings are owned only by `Naming`** — tag base (`emacs-<channel>-<date>`), asset, stem, checksums, bundle binary paths. `Core.Tag` adds only the `.N` suffix.
4. **Tags are computed per-cell at PUBLISH time** (Phase 5), never baked into the decide matrix (avoids a TOCTOU stale-tag race). `Core.Tag.next_tag/3` is pure over a tag SNAPSHOT and MUST be recomputed against a freshly-fetched list on each publish attempt.
5. **Targets are FAIL-CLOSED:** no explicit `enabled = true` ⇒ disabled.

---

## File Structure

- `mise.toml` (repo root) — pipeline toolchain pins (erlang/elixir now; pixi added Phase 1).
- `orchestrator/mix.exs` — project + the `:toml` dep.
- `orchestrator/lib/orchestrator/naming.ex` — `Orchestrator.Naming`.
- `orchestrator/lib/orchestrator/core/{hash,tag,detect,decide,latest}.ex` — the pure brain.
- `orchestrator/lib/orchestrator/manifest.ex` — versions × targets → jobs.
- `orchestrator/test/orchestrator/**` — one ExUnit file per module.
- `orchestrator/test/support/fixtures/{versions,targets}.toml` — loader-test fixtures.
- `versions.toml`, `targets.toml` (repo root) — the real manifest (v1: `master`, `macos-arm64`).
- `.github/workflows/orchestrator-ci.yml` — dev CI (`mix test` on PRs). **One workflow file per concern** — the Phase-5 release pipeline is a *separate* `daily.yml`; never co-locate.
- `docs/superpowers/validation-log.md` — recorded findings from the mise pixi-plugin spike.

---

## Branch setup (do once, before Task 1)

- [ ] **Confirm you are on a Phase 0 work branch off `main`** (created after the spec + this plan are committed to `main`):

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs
git checkout main
git checkout -b phase-0-orchestrator-core
git branch --show-current   # expect: phase-0-orchestrator-core
```

---

## Task 1: Scaffold the mix project

**Files:**
- Create: `mise.toml` (repo root) — pins the orchestrator toolchain (erlang/elixir); used identically by local dev and CI.
- Create: `orchestrator/mix.exs` (via generator, then edit)
- Create: `orchestrator/lib/orchestrator.ex` (via generator)
- Modify: default `orchestrator/test/orchestrator_test.exs`

> All `mix` commands in this plan run under mise — either via mise shell-activation, or by prefixing `mise exec -- `. Task 1 uses the explicit `mise exec --` form during bootstrap.

- [ ] **Step 1: Pin the toolchain with a repo-level `mise.toml`, then generate the project**

Create `mise.toml` (repo root) — the single source of truth used identically by local dev and CI (Task 9); pixi + the pixi plugins are added in Phase 1:

```toml
[tools]
erlang = "29"
elixir = "1.20.0-otp-29"

# Shared task seam: local dev, pregate (.pregate/linux.sh), and GitHub CI all invoke
# `mise run test` / `mise run lint` — one definition, three environments. `dir` is relative
# to this file's dir (repo root), so tasks run in orchestrator/ regardless of invocation cwd.
[tasks.test]
dir = "orchestrator"
run = "mix deps.get && mix test --warnings-as-errors"

[tasks.lint]
dir = "orchestrator"
run = "mix format --check-formatted"

[tasks.fmt]
dir = "orchestrator"
run = "mix format"
```

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs
mise trust && mise install && mise lock
mise exec -- mix new orchestrator
```

Expected: provisions erlang 29 / elixir 1.20.0-otp-29 and writes `mise.lock`; the first run may take a few minutes to provision the toolchain (mise caches it; CI caches the same install dir), then scaffolds `orchestrator/`.

- [ ] **Step 2: Add the TOML dependency and pin Elixir**

Edit `orchestrator/mix.exs` so it reads exactly:

```elixir
defmodule Orchestrator.MixProject do
  use Mix.Project

  def project do
    [
      app: :orchestrator,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [{:toml, "~> 0.7"}]
  end
end
```

- [ ] **Step 3: Fetch deps**

```bash
cd orchestrator && mise exec -- mix deps.get
```

Expected: fetches `toml 0.7.x`. If `~> 0.7` fails to resolve, run `mix hex.info toml` and pin the newest `0.x` listed.

- [ ] **Step 4: Replace the default test with a sanity test**

Overwrite `orchestrator/test/orchestrator_test.exs`:

```elixir
defmodule OrchestratorTest do
  use ExUnit.Case, async: true

  test "toolchain is wired (known empty-string sha256)" do
    assert :crypto.hash(:sha256, "") |> Base.encode16(case: :lower) ==
             "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  end
end
```

- [ ] **Step 5: Run the test with warnings as errors**

```bash
mise run test
```

Expected: PASS (1 test, 0 failures), no warnings. `mise run test` runs `mix deps.get && mix test --warnings-as-errors` in `orchestrator/` — the same task pregate and CI call. (During the per-module TDD loop below you can still run a single file directly, e.g. `mix test test/orchestrator/naming_test.exs`.)

- [ ] **Step 6: Commit**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs
git add mise.toml mise.lock orchestrator
git commit -m "chore(orchestrator): pin toolchain + scaffold mix project"
```

---

## Task 2: `Orchestrator.Naming` — the aqua contract owner

**Files:**
- Create: `orchestrator/lib/orchestrator/naming.ex`
- Test: `orchestrator/test/orchestrator/naming_test.exs`

- [ ] **Step 1: Write the failing test**

Create `orchestrator/test/orchestrator/naming_test.exs`:

```elixir
defmodule Orchestrator.NamingTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Naming

  @tag_str "emacs-master-2026-06-05"

  test "tag_base builds emacs-<channel>-<date>" do
    assert Naming.tag_base("master", "2026-06-05") == "emacs-master-2026-06-05"
  end

  test "asset_name matches the aqua template misemacs-<version>-<os>-<arch>.tar.gz" do
    assert Naming.asset_name(@tag_str, "macos", "arm64") ==
             "misemacs-emacs-master-2026-06-05-macos-arm64.tar.gz"
  end

  test "asset_name satisfies the aqua template shape" do
    name = Naming.asset_name(@tag_str, "macos", "arm64")
    assert Regex.match?(~r/^misemacs-.+-macos-arm64\.tar\.gz$/, name)
  end

  test "arch token passes through verbatim (the registry has NO arch replacement)" do
    # If aqua ever normalizes arm64->aarch64 this is the canary; the value we emit must
    # equal aqua's resolved {{.Arch}} (confirm via a real aqua resolve, Phase 0/4).
    assert Naming.asset_name(@tag_str, "macos", "arm64") =~ "-arm64.tar.gz"
    assert Naming.asset_name(@tag_str, "macos", "aarch64") =~ "-aarch64.tar.gz"
  end

  test "asset_stem is the asset name without .tar.gz (the tarball top dir)" do
    name = Naming.asset_name(@tag_str, "macos", "arm64")
    stem = Naming.asset_stem(@tag_str, "macos", "arm64")
    assert name == stem <> ".tar.gz"
  end

  test "checksums filename is SHASUMS256.txt" do
    assert Naming.checksums_filename() == "SHASUMS256.txt"
  end

  test "bundle binaries match the registry's expected extract paths" do
    bins = Naming.bundle_binaries()
    assert "Emacs.app/Contents/MacOS/Emacs" in bins
    assert "Emacs.app/Contents/MacOS/bin/emacsclient" in bins
    assert "Emacs.app/Contents/MacOS/bin/etags" in bins
    assert "Emacs.app/Contents/MacOS/bin/ebrowse" in bins
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd orchestrator && mix test test/orchestrator/naming_test.exs
```

Expected: FAIL (`Orchestrator.Naming` undefined).

- [ ] **Step 3: Implement the module**

Create `orchestrator/lib/orchestrator/naming.ex`:

```elixir
defmodule Orchestrator.Naming do
  @moduledoc """
  SOLE owner of release tag / asset / checksum name strings.

  These MUST match the aqua registry template
  (djgoku/aqua-registry@feat/djgoku/misemacs):

      misemacs-{{.Version}}-{{.OS}}-{{.Arch}}.tar.gz   (darwin -> macos, format tar.gz)

  where {{.Version}} is the git tag. Any drift here silently breaks `mise use aqua:...`.

  ARCH NOTE: the registry has NO arch replacement, so the `arch` passed in MUST equal the
  token aqua renders for the platform ({{.Arch}}). For darwin/arm64 that is expected to be
  `arm64`. [OPEN: confirm aqua's default arm64 token via a real `aqua` resolve — a silent
  arm64->aarch64 normalization would break installs.]
  """

  @asset_prefix "misemacs"
  @format "tar.gz"
  @checksums "SHASUMS256.txt"

  @doc "Base release tag for a channel/date: `emacs-<channel>-<date>` (no `.N` suffix)."
  @spec tag_base(String.t(), String.t()) :: String.t()
  def tag_base(channel, date), do: "emacs-#{channel}-#{date}"

  @doc "Release asset filename for a tag/os/arch."
  @spec asset_name(String.t(), String.t(), String.t()) :: String.t()
  def asset_name(tag, os, arch), do: "#{asset_stem(tag, os, arch)}.#{@format}"

  @doc "Top-level dir inside the tarball == asset name without the .tar.gz extension."
  @spec asset_stem(String.t(), String.t(), String.t()) :: String.t()
  def asset_stem(tag, os, arch), do: "#{@asset_prefix}-#{tag}-#{os}-#{arch}"

  @doc "Checksums asset filename attached to every release."
  @spec checksums_filename() :: String.t()
  def checksums_filename, do: @checksums

  @doc "Paths (relative to the stem dir) that aqua extracts onto PATH."
  @spec bundle_binaries() :: [String.t()]
  def bundle_binaries do
    [
      "Emacs.app/Contents/MacOS/Emacs",
      "Emacs.app/Contents/MacOS/bin/emacsclient",
      "Emacs.app/Contents/MacOS/bin/etags",
      "Emacs.app/Contents/MacOS/bin/ebrowse"
    ]
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
mix test test/orchestrator/naming_test.exs
```

Expected: PASS (7 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs
git add orchestrator/lib/orchestrator/naming.ex orchestrator/test/orchestrator/naming_test.exs
git commit -m "feat(naming): aqua tag/asset/checksum contract owner"
```

---

## Task 3: `Orchestrator.Core.Hash` — frozen fingerprint contract

**Files:**
- Create: `orchestrator/lib/orchestrator/core/hash.ex`
- Test: `orchestrator/test/orchestrator/core/hash_test.exs`

- [ ] **Step 1: Write the failing test**

Create `orchestrator/test/orchestrator/core/hash_test.exs`:

```elixir
defmodule Orchestrator.Core.HashTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Core.Hash

  @inputs %{
    toolchain_hash: "sha256:tc",
    upstream_sha: "deadbeef",
    mise_toml: "[env]\n",
    pixi_toml: "[project]\n",
    pixi_lock: "version: 6\n"
  }

  test "hash/1 is the known sha256, lowercase, prefixed" do
    assert Hash.hash("abc") ==
             "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  end

  test "toolchain_hash/2 is stable and flips on either input" do
    h = Hash.toolchain_hash("a", "b")
    assert h == Hash.toolchain_hash("a", "b")
    refute h == Hash.toolchain_hash("a", "b2")
    refute h == Hash.toolchain_hash("a2", "b")
  end

  test "version_fingerprint is stable for identical inputs" do
    assert Hash.version_fingerprint(@inputs) == Hash.version_fingerprint(@inputs)
  end

  test "a change in ANY fingerprint field flips the fingerprint" do
    for field <- Hash.fingerprint_fields() do
      changed = Map.update!(@inputs, field, &(&1 <> "X"))

      refute Hash.version_fingerprint(@inputs) == Hash.version_fingerprint(changed),
             "expected a #{field} change to flip the fingerprint"
    end
  end

  test "version_fingerprint requires the full §8 field set (fail-loud)" do
    assert_raise KeyError, fn -> Hash.version_fingerprint(Map.delete(@inputs, :pixi_lock)) end
  end

  test "the frozen field order matches spec §8" do
    assert Hash.fingerprint_fields() ==
             [:toolchain_hash, :upstream_sha, :mise_toml, :pixi_toml, :pixi_lock]
  end

  test "ordered fingerprint/1 is label-delimited (no field-boundary collision)" do
    refute Hash.fingerprint([{"f", "a"}, {"g", "b"}]) ==
             Hash.fingerprint([{"f", "ab"}, {"g", ""}])
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd orchestrator && mix test test/orchestrator/core/hash_test.exs
```

Expected: FAIL (`Orchestrator.Core.Hash` undefined).

- [ ] **Step 3: Implement the module**

Create `orchestrator/lib/orchestrator/core/hash.ex`:

```elixir
defmodule Orchestrator.Core.Hash do
  @moduledoc """
  Pure hashing for change detection. No IO.

  Fingerprint inputs are an ORDERED, NAMED list so a later IO caller cannot silently
  reorder or drop a field (which would mask a real change or trigger rebuild storms).
  Each entry is hashed as `label <NUL> bytes <NUL>`. Field `bytes` are assumed NUL-free
  (hex SHAs or text manifest files). Hash files to a hex digest first, then feed the
  DIGEST string into a fingerprint — never raw multi-record binary directly.
  """

  # The exact §8 fingerprint inputs, in the exact order. Freezing this is the point.
  @fingerprint_fields [:toolchain_hash, :upstream_sha, :mise_toml, :pixi_toml, :pixi_lock]

  @doc ~S(sha256 of iodata, as "sha256:" <> lowercase hex.)
  @spec hash(iodata()) :: String.t()
  def hash(iodata) do
    "sha256:" <> (:crypto.hash(:sha256, iodata) |> Base.encode16(case: :lower))
  end

  @doc "Toolchain hash = sha256 of the repo-level mise.toml ⧺ mise.lock (spec §8)."
  @spec toolchain_hash(iodata(), iodata()) :: String.t()
  def toolchain_hash(mise_toml, mise_lock) do
    fingerprint([{"mise_toml", mise_toml}, {"mise_lock", mise_lock}])
  end

  @doc """
  Hash an ordered, labeled list of `{label, bytes}` entries. Order and membership are
  part of the value — different order ⇒ different hash.
  """
  @spec fingerprint([{String.t(), iodata()}]) :: String.t()
  def fingerprint(entries) when is_list(entries) do
    entries
    |> Enum.flat_map(fn {label, bytes} -> [label, <<0>>, bytes, <<0>>] end)
    |> hash()
  end

  @doc """
  Canonical per-version fingerprint over the fixed §8 field set, in the fixed order.
  `inputs` MUST contain every key in `fingerprint_fields/0`; a missing key raises
  (fail-loud), so a caller cannot accidentally drop an input.
  """
  @spec version_fingerprint(map()) :: String.t()
  def version_fingerprint(inputs) do
    @fingerprint_fields
    |> Enum.map(fn field -> {Atom.to_string(field), Map.fetch!(inputs, field)} end)
    |> fingerprint()
  end

  @doc "The frozen fingerprint field order (for tests / callers)."
  @spec fingerprint_fields() :: [atom()]
  def fingerprint_fields, do: @fingerprint_fields
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
mix test test/orchestrator/core/hash_test.exs
```

Expected: PASS (7 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs
git add orchestrator/lib/orchestrator/core/hash.ex orchestrator/test/orchestrator/core/hash_test.exs
git commit -m "feat(core): frozen ordered fingerprint + toolchain hash"
```

---

## Task 4: `Orchestrator.Core.Tag` — date tag + `.N` collisions

**Files:**
- Create: `orchestrator/lib/orchestrator/core/tag.ex`
- Test: `orchestrator/test/orchestrator/core/tag_test.exs`

- [ ] **Step 1: Write the failing test**

Create `orchestrator/test/orchestrator/core/tag_test.exs`:

```elixir
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
    existing = ["emacs-master-2026-06-05", "emacs-master-2026-06-05.9", "emacs-master-2026-06-05.10"]
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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd orchestrator && mix test test/orchestrator/core/tag_test.exs
```

Expected: FAIL (`Orchestrator.Core.Tag` undefined).

- [ ] **Step 3: Implement the module**

Create `orchestrator/lib/orchestrator/core/tag.ex`:

```elixir
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
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
mix test test/orchestrator/core/tag_test.exs
```

Expected: PASS (9 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs
git add orchestrator/lib/orchestrator/core/tag.ex orchestrator/test/orchestrator/core/tag_test.exs
git commit -m "feat(core): date tag with .N collision + retry contract"
```

---

## Task 5: `Orchestrator.Core.Detect` — changed vs last release

**Files:**
- Create: `orchestrator/lib/orchestrator/core/detect.ex`
- Test: `orchestrator/test/orchestrator/core/detect_test.exs`

- [ ] **Step 1: Write the failing test**

Create `orchestrator/test/orchestrator/core/detect_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd orchestrator && mix test test/orchestrator/core/detect_test.exs
```

Expected: FAIL (`Orchestrator.Core.Detect` undefined).

- [ ] **Step 3: Implement the module**

Create `orchestrator/lib/orchestrator/core/detect.ex`:

```elixir
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
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
mix test test/orchestrator/core/detect_test.exs
```

Expected: PASS (5 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs
git add orchestrator/lib/orchestrator/core/detect.ex orchestrator/test/orchestrator/core/detect_test.exs
git commit -m "feat(core): change detection vs last-released state"
```

---

## Task 6: `Orchestrator.Core.Decide` — release plan + matrix join

**Files:**
- Create: `orchestrator/lib/orchestrator/core/decide.ex`
- Test: `orchestrator/test/orchestrator/core/decide_test.exs`

- [ ] **Step 1: Write the failing test**

Create `orchestrator/test/orchestrator/core/decide_test.exs`:

```elixir
defmodule Orchestrator.Core.DecideTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Core.Decide
  alias Orchestrator.Core.Decide.Plan

  @versions [%{name: "master", channel: "master", ref: "master"}]

  test "first run builds everything (nil manifest)" do
    states = %{"master" => %{upstream_sha: "a", inputs_hash: "h"}}
    plan = Decide.plan(@versions, states, nil, "2026-06-05")
    assert [%{name: "master", channel: "master", reason: :first_run}] = plan.build
    assert plan.skip == []
    assert plan.date == "2026-06-05"
  end

  test "no change => empty build, version skipped (the cadence rule)" do
    states = %{"master" => %{upstream_sha: "a", inputs_hash: "h"}}
    manifest = %{"versions" => %{"master" => %{"upstream_sha" => "a", "inputs_hash" => "h"}}}
    plan = Decide.plan(@versions, states, manifest, "2026-06-05")
    assert plan.build == []
    assert [%{name: "master", reason: :unchanged}] = plan.skip
  end

  test "changed inputs => build with :inputs" do
    states = %{"master" => %{upstream_sha: "a", inputs_hash: "h2"}}
    manifest = %{"versions" => %{"master" => %{"upstream_sha" => "a", "inputs_hash" => "h"}}}
    plan = Decide.plan(@versions, states, manifest, "2026-06-05")
    assert [%{name: "master", reason: :inputs}] = plan.build
  end

  test "mixed: one builds (upstream changed), one skips; build order preserved" do
    versions = [
      %{name: "master", channel: "master", ref: "master"},
      %{name: "emacs-30.2", channel: "30.2", ref: "emacs-30.2"}
    ]

    states = %{
      "master" => %{upstream_sha: "a2", inputs_hash: "h"},
      "emacs-30.2" => %{upstream_sha: "b", inputs_hash: "g"}
    }

    manifest = %{
      "versions" => %{
        "master" => %{"upstream_sha" => "a", "inputs_hash" => "h"},
        "emacs-30.2" => %{"upstream_sha" => "b", "inputs_hash" => "g"}
      }
    }

    plan = Decide.plan(versions, states, manifest, "2026-06-05")
    assert [%{name: "master", reason: :upstream_sha}] = plan.build
    assert [%{name: "emacs-30.2", reason: :unchanged}] = plan.skip
  end

  test "a version missing from current_states fails loud (KeyError)" do
    assert_raise KeyError, fn -> Decide.plan(@versions, %{}, nil, "2026-06-05") end
  end

  test "matrix/2 keeps only jobs whose version is in plan.build" do
    plan = %Plan{
      date: "2026-06-05",
      build: [%{name: "master", channel: "master", reason: :first_run, state: %{}}],
      skip: [%{name: "emacs-30.2", reason: :unchanged}]
    }

    jobs = [
      %{name: "master", channel: "master", ref: "master", target: "macos-arm64", os: "macos", arch: "arm64", runner: "macos-14"},
      %{name: "emacs-30.2", channel: "30.2", ref: "emacs-30.2", target: "macos-arm64", os: "macos", arch: "arm64", runner: "macos-14"}
    ]

    assert [%{name: "master"}] = Decide.matrix(plan, jobs)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd orchestrator && mix test test/orchestrator/core/decide_test.exs
```

Expected: FAIL (`Orchestrator.Core.Decide` undefined).

- [ ] **Step 3: Implement the module**

Create `orchestrator/lib/orchestrator/core/decide.ex`:

```elixir
defmodule Orchestrator.Core.Decide do
  @moduledoc """
  Pure release planning + matrix join. No IO.

  `plan/4` decides which versions build (the cadence gate: empty `build` ⇒ release
  nothing). `matrix/2` joins the plan against the full job list by `:name` to produce the
  per-cell build matrix the Phase-5 decide-job emits (wrap as `{"include": matrix}` for
  GitHub Actions `strategy.matrix`). Tags are computed per-cell at PUBLISH time
  (`Core.Tag`), never baked into the matrix here.
  """
  alias Orchestrator.Core.Detect

  defmodule Plan do
    @enforce_keys [:date]
    defstruct build: [], skip: [], date: nil

    @type build_entry :: %{name: String.t(), channel: String.t(), reason: atom(), state: map()}
    @type skip_entry :: %{name: String.t(), reason: atom()}
    @type t :: %__MODULE__{build: [build_entry()], skip: [skip_entry()], date: String.t()}
  end

  @doc """
  Build the release plan (build-order preserved — `Core.Latest` relies on it).

    * `versions`        — [%{name, channel, ref}]
    * `current_states`  — %{name => %{upstream_sha, inputs_hash}} (must contain every version; missing ⇒ raises)
    * `last_manifest`   — %{"versions" => %{name => %{"upstream_sha", "inputs_hash"}}} | nil
    * `date`            — "YYYY-MM-DD"
  """
  @spec plan([map()], map(), map() | nil, String.t()) :: Plan.t()
  def plan(versions, current_states, last_manifest, date) do
    {build, skip} =
      Enum.reduce(versions, {[], []}, fn v, {b, s} ->
        current = Map.fetch!(current_states, v.name)

        case Detect.changed?(current, previous_state(last_manifest, v.name)) do
          {true, reason} ->
            {[%{name: v.name, channel: v.channel, reason: reason, state: current} | b], s}

          {false, reason} ->
            {b, [%{name: v.name, reason: reason} | s]}
        end
      end)

    %Plan{date: date, build: Enum.reverse(build), skip: Enum.reverse(skip)}
  end

  @doc """
  Join a plan against the full job list (`Orchestrator.Manifest.jobs/2` output) by
  `:name`, yielding the per-cell build matrix (changed versions × their targets). Only
  jobs whose version is in `plan.build` survive; job order is preserved.
  """
  @spec matrix(Plan.t(), [map()]) :: [map()]
  def matrix(%Plan{build: build}, jobs) do
    names = MapSet.new(build, & &1.name)
    Enum.filter(jobs, &MapSet.member?(names, &1.name))
  end

  defp previous_state(nil, _name), do: nil

  defp previous_state(manifest, name) do
    case get_in(manifest, ["versions", name]) do
      nil -> nil
      e -> %{upstream_sha: e["upstream_sha"], inputs_hash: e["inputs_hash"]}
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
mix test test/orchestrator/core/decide_test.exs
```

Expected: PASS (6 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs
git add orchestrator/lib/orchestrator/core/decide.ex orchestrator/test/orchestrator/core/decide_test.exs
git commit -m "feat(core): release plan + matrix join"
```

---

## Task 7: `Orchestrator.Core.Latest` — which tag becomes `latest`

**Files:**
- Create: `orchestrator/lib/orchestrator/core/latest.ex`
- Test: `orchestrator/test/orchestrator/core/latest_test.exs`

- [ ] **Step 1: Write the failing test**

Create `orchestrator/test/orchestrator/core/latest_test.exs`:

```elixir
defmodule Orchestrator.Core.LatestTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Core.Latest

  test "nothing built => :unchanged" do
    assert Latest.latest_target([]) == :unchanged
  end

  test "a single build becomes latest" do
    assert Latest.latest_target(["emacs-master-2026-06-05"]) == {:set, "emacs-master-2026-06-05"}
  end

  test "the last (newest) built tag in recency order is chosen" do
    assert Latest.latest_target(["a", "b", "c"]) == {:set, "c"}
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd orchestrator && mix test test/orchestrator/core/latest_test.exs
```

Expected: FAIL (`Orchestrator.Core.Latest` undefined).

- [ ] **Step 3: Implement the module**

Create `orchestrator/lib/orchestrator/core/latest.ex`:

```elixir
defmodule Orchestrator.Core.Latest do
  @moduledoc """
  Pure 'latest' selection. No IO.

  v1 policy: the newest build of the run becomes `latest`. The caller (Phase 5
  `finalize`) MUST pass `built_tags` in release-recency order (oldest → newest); the last
  element is chosen. `:unchanged` when nothing was built. (Per-channel `latest` is a
  future enhancement; spec §11.1.)
  """
  @spec latest_target([String.t()]) :: {:set, String.t()} | :unchanged
  def latest_target([]), do: :unchanged
  def latest_target(built_tags) when is_list(built_tags), do: {:set, List.last(built_tags)}
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
mix test test/orchestrator/core/latest_test.exs
```

Expected: PASS (3 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs
git add orchestrator/lib/orchestrator/core/latest.ex orchestrator/test/orchestrator/core/latest_test.exs
git commit -m "feat(core): latest-release selection"
```

---

## Task 8: `Orchestrator.Manifest` + the real manifest files

**Files:**
- Create: `orchestrator/lib/orchestrator/manifest.ex`
- Create: `orchestrator/test/orchestrator/manifest_test.exs`
- Create: `orchestrator/test/support/fixtures/versions.toml`
- Create: `orchestrator/test/support/fixtures/targets.toml`
- Create: `versions.toml` (repo root)
- Create: `targets.toml` (repo root)

- [ ] **Step 1: Write the fixture manifests**

Create `orchestrator/test/support/fixtures/versions.toml` (table key == ref; `channel` is the short form):

```toml
[versions.master]
ref = "master"
channel = "master"

[versions."emacs-30.2"]
ref = "emacs-30.2"
channel = "30.2"
```

Create `orchestrator/test/support/fixtures/targets.toml`:

```toml
[targets.macos-arm64]
os = "macos"
arch = "arm64"
runner = "macos-14"
enabled = true

[targets.linux-arm64]
os = "linux"
arch = "arm64"
runner = "ubuntu-24.04-arm"
enabled = false
```

- [ ] **Step 2: Write the failing test**

Create `orchestrator/test/orchestrator/manifest_test.exs`:

```elixir
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
      "macos-arm64" => %{"os" => "macos", "arch" => "arm64", "runner" => "macos-14", "enabled" => true}
    }

    jobs = Manifest.jobs(versions, targets)
    assert length(jobs) == 2
    assert Enum.any?(jobs, &(&1.name == "master" and &1.os == "macos" and &1.arch == "arm64"))
    assert Enum.any?(jobs, &(&1.name == "emacs-30.2" and &1.channel == "30.2"))
  end

  test "jobs/2 omits disabled targets" do
    versions = %{"master" => %{"channel" => "master", "ref" => "master"}}

    targets = %{
      "macos-arm64" => %{"os" => "macos", "arch" => "arm64", "runner" => "macos-14", "enabled" => true},
      "linux-arm64" => %{"os" => "linux", "arch" => "arm64", "runner" => "ubuntu-24.04-arm", "enabled" => false}
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
    targets = %{"macos-arm64" => %{"os" => "macos", "arch" => "arm64", "runner" => "macos-14", "enabled" => true}}
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
```

- [ ] **Step 3: Run it to verify it fails**

```bash
cd orchestrator && mix test test/orchestrator/manifest_test.exs
```

Expected: FAIL (`Orchestrator.Manifest` undefined; the repo-root test also fails until Step 5).

- [ ] **Step 4: Implement the module**

Create `orchestrator/lib/orchestrator/manifest.ex`:

```elixir
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
```

- [ ] **Step 5: Create the real repo-root manifest**

Create `versions.toml` (repo root):

```toml
# THE manifest. Adding a version = one entry here + a versions/<name>/ dir.
# Table key == git ref (the join key / versions/<name>/ dir); channel is the short form.
[versions.master]
ref = "master"        # git ref in emacs-mirror/emacs
channel = "master"    # used in the tag: emacs-master-YYYY-MM-DD
```

Create `targets.toml` (repo root):

```toml
# The OS × arch matrix. v1 = macos-arm64 only. Fail-closed: enabled must be explicit.
[targets.macos-arm64]
os = "macos"          # aqua {{.OS}} after darwin->macos replacement
arch = "arm64"        # aqua {{.Arch}}
runner = "macos-14"   # arm64 hosted runner
enabled = true
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
cd orchestrator && mix test test/orchestrator/manifest_test.exs
```

Expected: PASS (6 tests, 0 failures).

- [ ] **Step 7: Run the full suite with warnings as errors**

```bash
mise run test    # full suite, warnings-as-errors — the same task pregate/CI run
mise run lint    # mix format --check-formatted (run `mise run fmt` to auto-fix)
```

Expected: both PASS — all modules green, no warnings, formatting clean.

- [ ] **Step 8: Commit**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs
git add orchestrator/lib/orchestrator/manifest.ex orchestrator/test/orchestrator/manifest_test.exs \
        orchestrator/test/support/fixtures/versions.toml orchestrator/test/support/fixtures/targets.toml \
        versions.toml targets.toml
git commit -m "feat(manifest): versions × targets job matrix + v1 manifest"
```

---

## Task 9: Dev CI — `mix test` gate on PRs

A cheap Ubuntu gate (seconds, no macOS minutes) that re-proves the brain on every PR
touching `orchestrator/`. Distinct from the Phase-5 release pipeline (a separate
`daily.yml`). Uses **`jdx/mise-action`** so the gate provisions the toolchain from the
repo-level `mise.toml`/`mise.lock` — **local == CI parity**: a contributor's `mise install`
and the runner install the identical pinned tools, no version drift. The gate runs the
**shared mise tasks** `mise run test` / `mise run lint` — the *exact* commands you run
locally and that pregate runs in clean macOS + Linux VMs (Step 4) — so all three
environments stay in lockstep. mise-action caches the install dir, so subsequent runs are fast (the first run
provisions erlang/elixir).

**Files:**
- Create: `.github/workflows/orchestrator-ci.yml`
- Create: `.pregate/{common,linux,macos}.sh` (optional — clean-VM pre-push gate, both OSes)

- [ ] **Step 1: Create the workflow**

Create `.github/workflows/orchestrator-ci.yml`:

```yaml
name: orchestrator-ci
on:
  pull_request:
    paths: ["orchestrator/**", "mise.toml", "mise.lock", ".github/workflows/orchestrator-ci.yml"]
permissions:
  contents: read
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v2   # installs the toolchain from mise.toml (cached)
      - run: mise run test   # mix deps.get && mix test --warnings-as-errors (in orchestrator/)
      - run: mise run lint   # mix format --check-formatted
```

- [ ] **Step 2: Lint the YAML locally**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/orchestrator-ci.yml')); print('YAML OK')"
```

Expected: `YAML OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/orchestrator-ci.yml
git commit -m "ci: mix test gate on orchestrator PRs"
```

- [ ] **Step 4: (optional) Add pregate recipes — clean-VM pre-push gate (macOS + Linux)**

pregate clones disposable **macOS + Linux** VMs, pipes your working tree in (excluding
`.git`/build dirs), and runs `.pregate/<os>.sh`. Point both at the same shared mise tasks
via a common script, so a green `pregate` predicts a green GitHub CI run. (For the
orchestrator both OSes run identically; in Phase 2+ `macos.sh` will carry the real emacs
build — pre-validating in a clean macOS VM *before* spending GitHub macOS-runner minutes.)

Create `.pregate/common.sh` (shared body):

```sh
#!/bin/sh
# shared pregate steps, sourced by macos.sh + linux.sh. cwd = source tree.
# Avoid exit codes 10-12 (reserved by pregate).
set -eu
ver=$(mise --version 2>/dev/null) || ver=""
[ -n "$ver" ] || { echo "FATAL: mise missing/broken in the $PREGATE_OS image"; exit 1; }
mise trust >/dev/null 2>&1 || true
mise install        # provision the pinned toolchain in the fresh VM
mise run test
mise run lint
```

Create `.pregate/linux.sh` and `.pregate/macos.sh` — each just sources the shared body:

```sh
#!/bin/sh
. ./.pregate/common.sh
```

Then, before pushing:

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs
git add .pregate/common.sh .pregate/linux.sh .pregate/macos.sh
git commit -m "ci: pregate recipes (macos+linux) via mise run test/lint"
pregate            # runs every OS with a recipe (macOS + Linux) in parallel
# variants: pregate --linux   |   pregate --verbose
```

Note: each base image must provide `mise` (pregate's own recipe assumes this); if not,
prepend `curl https://mise.run | sh` before `mise install`, or point at mise-equipped
images via `--linux-image` / `--macos-image`.

Note: the `orchestrator-ci.yml` workflow only runs once it is on `main` (or the PR's base
has it). It first exercises on the Phase 0 merge PR — confirm it goes green there.

---

## Task 10: Validate the mise pixi-plugin path (spike, informs Phase 1)

One-off validation (not TDD). Resolves spec §13 opens: the backend **prefix**, whether
the backend locks transitively, whether a pixi **project** locks transitively, and the
**tree-sitter** lib+headers question. Uses a FIXED throwaway dir so variables survive
across steps. Record findings; wire nothing into the build yet.

**Files:**
- Create: `docs/superpowers/validation-log.md`

- [ ] **Step 1: Install the backend plugin and DISCOVER its prefix (do not assume `pixi:`)**

```bash
mise plugin install pixi https://github.com/esteve/mise-backend-pixi
mise plugin ls
# Probe both prefixes; whichever LISTS versions is the real one (pkg-config is conda-only):
echo "--- try pixi: ---";      mise ls-remote pixi:pkg-config 2>&1 | tail -3
echo "--- try vfox-pixi: ---"; mise ls-remote vfox-pixi:pkg-config 2>&1 | tail -3
```

Record the working `PREFIX` (`pixi:` or `vfox-pixi:`). Every step below uses it.

- [ ] **Step 2: Confirm the backend installs a CONDA-ONLY tool + check lock behavior**

`pkg-config` is conda-forge-only (verified NOT in the mise registry), so success here
proves the backend — not a registry fallback. Substitute `<PREFIX>` from Step 1:

```bash
WORK="${TMPDIR:-/tmp}/misemacs-phase0-validation"; mkdir -p "$WORK/backend"; cd "$WORK/backend"
mise use <PREFIX>pkg-config@latest
mise lock                       # mise.lock is NOT auto-created; generate before inspecting
mise where <PREFIX>pkg-config   # EXPECT a pixi/conda install path, NOT a registry/aqua path
mise exec -- pkg-config --version
echo "=== mise.lock ==="; cat mise.lock 2>/dev/null || echo "NO mise.lock"
```

Record: did it install via the backend (`mise where` → pixi/conda path)? Does `mise.lock`
record it, and does it carry transitive deps + checksums, or only the top-level package?

- [ ] **Step 3: Confirm a pixi PROJECT locks transitively via `pixi.lock`**

This is the mechanism the spec uses for build libs (mise-env-pixi activates a project):

```bash
WORK="${TMPDIR:-/tmp}/misemacs-phase0-validation"; mkdir -p "$WORK/project"; cd "$WORK/project"
mise exec pixi -- pixi init --platform osx-arm64
mise exec pixi -- pixi add gnutls libxml2 jansson
mise exec pixi -- pixi install
echo "=== transitive closure proof (EXPECT non-empty) ==="
grep -Eio 'nettle|gmp|p11-kit|libtasn1' pixi.lock | sort -u
```

Expected: the grep returns nettle/gmp/p11-kit/libtasn1 (gnutls' closure) → `pixi.lock`
locks transitive deps → D7 confirmed.

- [ ] **Step 4: Check tree-sitter LIBRARY + headers (the v1-optional dep)**

```bash
WORK="${TMPDIR:-/tmp}/misemacs-phase0-validation"; cd "$WORK/project"
mise exec pixi -- pixi add tree-sitter 2>&1 | tail -20
find "$WORK/project/.pixi" \( -name 'libtree-sitter*' -o -name 'tree_sitter.h' \) -print 2>/dev/null | head
# conda-forge may split headers into a separate output/package — check before concluding:
mise exec pixi -- pixi search tree-sitter 2>&1 | tail -20 || true
```

Record: does conda-forge `tree-sitter` ship `libtree-sitter` + `tree_sitter.h` (possibly
via a separate package)? If genuinely unavailable, `--with-tree-sitter` is DROPPED from
v1 (spec §6.2).

- [ ] **Step 5: Record findings**

Create `docs/superpowers/validation-log.md` (fill in REAL results):

```markdown
# Validation Log

## 2026-06-05 — Phase 0: mise pixi-plugin path

- **Backend prefix:** `pixi:` works? / `vfox-pixi:` required? → Result: …
- **Backend installs conda-only `pkg-config`:** `mise where` path = … (pixi/conda? yes/no)
- **`mise.lock` transitive lock:** generated after `mise lock`? records transitive deps? → Result: …
- **Pixi project transitive lock (`pixi.lock`):** nettle/gmp/p11-kit/libtasn1 present? → D7 CONFIRMED / NOT.
- **conda-forge tree-sitter lib+headers:** libtree-sitter + tree_sitter.h present (or separate pkg)? → v1 `--with-tree-sitter` KEEP / DROP.
- **Phase 1 decision:** build libs via pixi PROJECT (mise-env-pixi); `<PREFIX>tool` for ad-hoc tools only; tree-sitter kept/dropped.
```

- [ ] **Step 6: Clean up and commit the log**

```bash
WORK="${TMPDIR:-/tmp}/misemacs-phase0-validation"; rm -rf "$WORK"
cd /Users/dj_goku/dev/github/djgoku/misemacs
git add docs/superpowers/validation-log.md
git commit -m "docs: record mise pixi-plugin validation findings"
```

---

## Phase 0 Definition of Done

- [ ] `mise run test` and `mise run lint` are green (all modules, no warnings, formatting clean) — the same tasks local/pregate/CI run.
- [ ] `Orchestrator.Naming` output matches the aqua template verbatim; arch token passes through verbatim (Task 2).
- [ ] Fingerprint input set is frozen, ordered, and fail-loud; `toolchain_hash` owned in `Core.Hash` (Task 3).
- [ ] `.N` collision + gap + "suffix present, base absent" + numeric-order + retry-grow cases proven (Task 4).
- [ ] "No change ⇒ empty build ⇒ no release" + `matrix/2` join + missing-state fail-loud proven (Tasks 5–6).
- [ ] `Core.Latest` recency-order contract documented + tested (Task 7).
- [ ] `versions.toml`/`targets.toml` parse into the expected jobs; fail-closed `enabled`; `name`-as-join-key invariant tested (Task 8).
- [ ] `orchestrator-ci.yml` present (runs `mise run test`/`lint`) and green on the Phase 0 merge PR; optional `.pregate/{linux,macos}.sh` mirror it (Task 9).
- [ ] `docs/superpowers/validation-log.md` records the pixi-plugin verdicts (Task 10).
- [ ] Branch `phase-0-orchestrator-core` ready to merge to `main`.

---

## Self-Review (completed by author)

**Spec coverage:** Phase 0 row of spec §14 → Tasks 2–8 + 10. Fingerprint (§8) → `Core.Hash`
ordered/named + `toolchain_hash` (Task 3), feeding `Core.Detect`/`Core.Decide` (Tasks 5–6).
Tag scheme + `.N` + retry contract (§11.1) → `Core.Tag` (Task 4). "latest" (§11.1) →
`Core.Latest` (Task 7). aqua contract (§10) → `Naming` (Task 2). "Add a version = data"
(§5) → `Manifest` + manifest files (Task 8). The Phase-5 dynamic matrix (§11.2) is fed by
`Decide.matrix/2` (Task 6, joins `plan.build ⋈ Manifest.jobs/2` by `name`; the decide-job
wraps it as `{"include": …}`) — NOT raw `jobs/2`. Dev CI (process review) → Task 9. Open
questions (§13) on the pixi plugins → Task 10. IO adapters, build, packaging, release CI =
later phases (out of Phase 0 by design).

**Placeholder scan:** No TBD/TODO; every code step shows complete code. Task 10's
`<PREFIX>` and the validation-log template are explicit "fill in real results" markers, not
unfinished plan content.

**Type consistency:** `state` map shape `%{upstream_sha, inputs_hash}` is identical across
`Core.Detect` and `Core.Decide`. `Decide.plan/4` build entries (`:name,:channel,:reason,:state`)
and `Manifest` job keys (`:name,:channel,:ref,:target,:os,:arch,:runner`) are stable; `matrix/2`
joins on `:name` (the documented invariant). `Naming.tag_base/2` is called by `Core.Tag.next_tag/3`.
`Core.Hash.version_fingerprint/1` owns the `%{toolchain_hash,upstream_sha,mise_toml,pixi_toml,pixi_lock}`
shape; `fingerprint_fields/0` is the single source of that order. `Core.Latest.latest_target/1`
(single arity) is used consistently.
