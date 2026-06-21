defmodule Orchestrator.Relocate.Enchant do
  @moduledoc """
  Enchant-specific bundling for `Orchestrator.Relocate` (Layout A).

  Enchant is an ORPHAN — nothing in Emacs links it (jinx's runtime-compiled module `dlopen`s
  it), so the generic closure walk can't discover it. We SEED the `dlopen`'d provider modules
  into `Contents/lib/enchant-2/` *before* the walk, so `Relocate.run` finds them as `app/**`
  Mach-O, pulls their closure (libenchant + glib + hunspell + libc++) into `Contents/Frameworks`,
  and gives each provider a depth-correct `@loader_path/../../Frameworks` rpath. libenchant's
  self-relocate constructor then computes its prefix as `<dir-of-libenchant>/..` = `Contents`,
  so it resolves the seeded providers at `Contents/lib/enchant-2` with no env var.

  Then we bundle the non-Mach-O payload the generic relocate doesn't touch: the `-lenchant-2`
  link-name symlink (for jinx's first-use compile) and an SDK dir under
  `Contents/Resources/enchant-sdk/` (headers, `enchant-2.pc`, an AppleSpell-first ordering,
  AppleSpell language mapping, and the hunspell `en_US` dict — the template `site-start.el` seeds
  a writable `ENCHANT_CONFIG_DIR` from).

  Every step is conditional on the build env actually shipping enchant
  (`<build_libdir>/enchant-2/`), so a non-enchant build relocates exactly as before.
  """

  # Prefer macOS AppleSpell while retaining bundled hunspell as a deterministic fallback.
  @ordering "*:AppleSpell,hunspell\n"
  # AppleSpell's provider reads AppleSpell.config and maps enchant tags to NSSpellChecker language
  # names. On macOS, NSSpellChecker generally exposes English as "en", not "en_US".
  @apple_spell_config "en_US en en\n"

  @doc "True if the build env ships enchant providers (so the enchant steps should run)."
  @spec present?(Path.t()) :: boolean
  def present?(build_libdir), do: File.dir?(Path.join(build_libdir, "enchant-2"))

  @doc """
  Seed the `dlopen`'d provider modules into `Contents/lib/enchant-2/` BEFORE the closure walk,
  so `Relocate.run` discovers them as `app/**` Mach-O and pulls their dep closure into Frameworks.
  """
  @spec seed_providers(Path.t(), Path.t()) :: :ok
  def seed_providers(app, build_libdir) do
    if present?(build_libdir) do
      dest = Path.join([app, "Contents", "lib", "enchant-2"])
      File.mkdir_p!(dest)

      # lib/enchant-2/ is enchant's provider dir by definition — seed every module it ships
      # (enchant_hunspell.so + enchant_applespell.so for our build).
      for so <- Path.wildcard(Path.join([build_libdir, "enchant-2", "*.so"])) do
        File.cp!(so, Path.join(dest, Path.basename(so)))
      end
    end

    :ok
  end

  @doc """
  After the Mach-O rewrite (libenchant now lives in Frameworks) and BEFORE signing (so it gets
  sealed), add the non-Mach-O payload: the `-lenchant-2` link-name symlink in Frameworks plus the
  SDK (headers, `enchant-2.pc`, AppleSpell-first ordering, AppleSpell mapping, hunspell dict) under
  `Contents/Resources/enchant-sdk/`.
  """
  @spec bundle_sdk(Path.t(), Path.t()) :: :ok
  def bundle_sdk(app, build_libdir) do
    if present?(build_libdir) do
      prefix = Path.dirname(build_libdir)
      fw = Path.join([app, "Contents", "Frameworks"])
      sdk = Path.join([app, "Contents", "Resources", "enchant-sdk"])

      # The rpath rewrite (install_name_tool) invalidated the providers' code signatures, and the
      # bundle's `codesign --deep` does NOT cover Contents/lib/enchant-2 (a non-standard nested
      # location). Re-sign each provider now — after the rewrite, before the bundle sign seals them —
      # else loading them via dlopen SIGKILLs on arm64 (AMFI). The otool gate can't catch this.
      for so <- Path.wildcard(Path.join([app, "Contents", "lib", "enchant-2", "*.so"])) do
        {_, 0} = System.cmd("codesign", ["--force", "--sign", "-", so], stderr_to_stdout: true)
      end

      # -lenchant-2 link name -> the versioned dylib the walk placed in Frameworks.
      link = Path.join(fw, "libenchant-2.dylib")

      if File.exists?(Path.join(fw, "libenchant-2.2.dylib")) and not link_exists?(link) do
        File.ln_s!("libenchant-2.2.dylib", link)
      end

      # SDK headers, flattened so jinx compiles with a single -I<sdk>/include.
      copy_dir(Path.join([prefix, "include", "enchant-2"]), Path.join(sdk, "include"))

      cp_if(
        Application.app_dir(:orchestrator, ["priv", "enchant", "misemacs-jinx-enchant-env.h"]),
        Path.join([sdk, "include", "misemacs-jinx-enchant-env.h"])
      )

      # enchant-2.pc (reference; jinx wires -I/-L directly, no pkg-config).
      cp_if(
        Path.join([build_libdir, "pkgconfig", "enchant-2.pc"]),
        Path.join(sdk, "enchant-2.pc")
      )

      # Writable ENCHANT_CONFIG_DIR template (site-start.el seeds a per-user copy from this):
      # AppleSpell-first ordering + AppleSpell language mapping + the hunspell fallback dict.
      config = Path.join(sdk, "config")
      File.rm_rf!(config)
      File.mkdir_p!(config)
      File.write!(Path.join(config, "enchant.ordering"), @ordering)
      File.write!(Path.join(config, "AppleSpell.config"), @apple_spell_config)

      dicts = Path.join([prefix, "share", "hunspell_dictionaries"])

      for ext <- ["aff", "dic"] do
        cp_if(Path.join(dicts, "en_US.#{ext}"), Path.join([config, "hunspell", "en_US.#{ext}"]))
      end

      # site-start.el: jinx <-> enchant wiring, auto-loaded at startup from the app's site-lisp.
      cp_if(
        Application.app_dir(:orchestrator, ["priv", "enchant", "site-start.el"]),
        Path.join([app, "Contents", "Resources", "site-lisp", "site-start.el"])
      )
    end

    :ok
  end

  defp copy_dir(src, dest) do
    if File.dir?(src) do
      File.mkdir_p!(dest)
      for f <- File.ls!(src), do: cp_if(Path.join(src, f), Path.join(dest, f))
    end
  end

  defp cp_if(src, dest) do
    if File.exists?(src) do
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(src, dest)
    end
  end

  # File.exists?/1 follows symlinks (false for a dangling link); we want "is there a link here?".
  defp link_exists?(path), do: match?({:ok, _}, File.read_link(path))
end
