defmodule Orchestrator.RelocateTest do
  use ExUnit.Case, async: false
  @moduletag :macos

  # Simulates a post-sign bundle mutation: signs for real, then tampers a sealed
  # dylib — verify_bundle must catch this (spec 2026-06-11 §3.1).
  defmodule TamperAfterSignTool do
    @behaviour Orchestrator.Macho.Tool
    alias Orchestrator.Macho.Otool
    defdelegate macho?(p), to: Otool
    defdelegate id(p), to: Otool
    defdelegate deps(p), to: Otool
    defdelegate rpaths(p), to: Otool
    defdelegate set_id(p, new), to: Otool
    defdelegate change(p, old, new), to: Otool
    defdelegate add_rpath(p, rp), to: Otool
    defdelegate delete_rpath(p, rp), to: Otool
    defdelegate verify_bundle(p), to: Otool

    def sign_bundle(app) do
      :ok = Otool.sign_bundle(app)
      tampered = Path.join([app, "Contents", "Frameworks", "libfoo.dylib"])
      File.write!(tampered, <<0>>, [:append])
      :ok
    end
  end

  setup do
    t = Path.join(System.tmp_dir!(), "reloc-#{System.unique_integer([:positive])}")
    app = Path.join(t, "App.app")
    File.mkdir_p!(Path.join([t, "buildlib"]))
    File.mkdir_p!(Path.join([app, "Contents", "MacOS", "bin"]))

    # A valid bundle requires Info.plist so codesign --deep doesn't complain about bundle format
    File.write!(Path.join([app, "Contents", "Info.plist"]), """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleExecutable</key><string>App</string>
      <key>CFBundleIdentifier</key><string>com.test.relocate</string>
      <key>CFBundleName</key><string>App</string>
      <key>CFBundlePackageType</key><string>APPL</string>
    </dict>
    </plist>
    """)

    # A nested non-Mach-O helper reproduces the original failure: per-file signing of the
    # main executable would trigger bundle mode and fail on this unsigned non-Mach-O helper
    File.mkdir_p!(Path.join([app, "Contents", "MacOS", "libexec"]))
    script = Path.join([app, "Contents", "MacOS", "libexec", "helper.sh"])
    File.write!(script, "#!/bin/sh\necho hi\n")
    File.chmod!(script, 0o755)

    on_exit(fn -> File.rm_rf!(t) end)
    {:ok, t: t}
  end

  defp clang!(args), do: {_, 0} = System.cmd("clang", args, stderr_to_stdout: true)

  test "relocate makes a fixture bundle self-contained; runs with build libdir moved aside", %{
    t: t
  } do
    lib = Path.join(t, "buildlib")
    app = Path.join(t, "App.app")
    File.write!(Path.join(t, "bar.c"), "int bar(void){return 5;}\n")
    File.write!(Path.join(t, "foo.c"), "int bar(void); int foo(void){return bar()+2;}\n")
    File.write!(Path.join(t, "main.c"), "int foo(void); int main(void){return foo()-7;}\n")

    clang!([
      "-dynamiclib",
      "-install_name",
      "@rpath/libbar.dylib",
      "-Wl,-headerpad_max_install_names",
      Path.join(t, "bar.c"),
      "-o",
      Path.join(lib, "libbar.dylib")
    ])

    clang!([
      "-dynamiclib",
      "-install_name",
      "@rpath/libfoo.dylib",
      "-Wl,-headerpad_max_install_names",
      "-L",
      lib,
      "-lbar",
      "-Wl,-rpath," <> lib,
      Path.join(t, "foo.c"),
      "-o",
      Path.join(lib, "libfoo.dylib")
    ])

    for out <- ["Contents/MacOS/App", "Contents/MacOS/bin/helper"] do
      clang!([
        "-Wl,-headerpad_max_install_names",
        "-L",
        lib,
        "-lfoo",
        "-Wl,-rpath," <> lib,
        Path.join(t, "main.c"),
        "-o",
        Path.join(app, out)
      ])
    end

    assert Orchestrator.Relocate.run(app, lib) == :ok

    assert {_, 0} =
             System.cmd("codesign", ["--verify", "--deep", "--strict", app],
               stderr_to_stdout: true
             )

    {dv, 0} = System.cmd("codesign", ["-dv", app], stderr_to_stdout: true)
    assert dv =~ "Signature=adhoc"
    assert File.exists?(Path.join([app, "Contents", "Frameworks", "libfoo.dylib"]))
    assert File.exists?(Path.join([app, "Contents", "Frameworks", "libbar.dylib"]))

    # clean-machine proxy: remove the build libdir; both binaries must still run (rc 0 == foo()==7).
    File.rename!(lib, lib <> ".gone")

    for out <- ["Contents/MacOS/App", "Contents/MacOS/bin/helper"] do
      assert {_, 0} = System.cmd(Path.join(app, out), [], stderr_to_stdout: true)
    end
  end

  test "relocate rewrites a foreign-absolute install_name dep to @rpath and bundles it", %{t: t} do
    lib = Path.join(t, "buildlib")
    app = Path.join(t, "App.app")
    File.write!(Path.join(t, "bar.c"), "int bar(void){return 5;}\n")
    File.write!(Path.join(t, "mainabs.c"), "int bar(void); int main(void){return bar()-5;}\n")
    abs = Path.join(lib, "libabs.dylib")
    # ABSOLUTE install_name (a foreign path), NOT @rpath:
    clang!([
      "-dynamiclib",
      "-install_name",
      abs,
      "-Wl,-headerpad_max_install_names",
      Path.join(t, "bar.c"),
      "-o",
      abs
    ])

    app_bin = Path.join(app, "Contents/MacOS/App")

    clang!([
      "-Wl,-headerpad_max_install_names",
      abs,
      Path.join(t, "mainabs.c"),
      "-o",
      app_bin
    ])

    # sanity: dep is foreign-absolute
    assert Orchestrator.Macho.classify(abs) == :foreign

    assert Orchestrator.Relocate.run(app, lib) == :ok

    assert {_, 0} =
             System.cmd("codesign", ["--verify", "--deep", "--strict", app],
               stderr_to_stdout: true
             )

    assert File.exists?(Path.join([app, "Contents", "Frameworks", "libabs.dylib"]))
    deps = Orchestrator.Macho.Otool.deps(app_bin)
    # the absolute ref was rewritten
    assert "@rpath/libabs.dylib" in deps
    refute abs in deps

    # clean-machine proxy
    File.rename!(lib, lib <> ".gone")
    assert {_, 0} = System.cmd(app_bin, [], stderr_to_stdout: true)
  end

  test "relocate fails with {:signature_invalid, _} when the bundle is mutated after signing",
       %{t: t} do
    lib = Path.join(t, "buildlib")
    app = Path.join(t, "App.app")
    File.write!(Path.join(t, "bar.c"), "int bar(void){return 5;}\n")
    File.write!(Path.join(t, "main.c"), "int bar(void); int main(void){return bar()-5;}\n")

    clang!([
      "-dynamiclib",
      "-install_name",
      "@rpath/libfoo.dylib",
      "-Wl,-headerpad_max_install_names",
      Path.join(t, "bar.c"),
      "-o",
      Path.join(lib, "libfoo.dylib")
    ])

    clang!([
      "-Wl,-headerpad_max_install_names",
      "-L",
      lib,
      "-lfoo",
      "-Wl,-rpath," <> lib,
      Path.join(t, "main.c"),
      "-o",
      Path.join(app, "Contents/MacOS/App")
    ])

    assert {:error, {:signature_invalid, reason}} =
             Orchestrator.Relocate.run(app, lib, TamperAfterSignTool)

    assert reason =~ "failed strict validation"
  end

  test "relocate returns {:error, violations} when a dep cannot be resolved", %{t: t} do
    lib = Path.join(t, "buildlib")
    app = Path.join(t, "App.app")
    File.write!(Path.join(t, "bar.c"), "int bar(void){return 5;}\n")
    File.write!(Path.join(t, "mainmiss.c"), "int bar(void); int main(void){return bar()-5;}\n")

    clang!([
      "-dynamiclib",
      "-install_name",
      "@rpath/libmissing.dylib",
      "-Wl,-headerpad_max_install_names",
      Path.join(t, "bar.c"),
      "-o",
      Path.join(lib, "libmissing.dylib")
    ])

    app_bin = Path.join(app, "Contents/MacOS/App")

    clang!([
      "-Wl,-headerpad_max_install_names",
      "-L",
      lib,
      "-lmissing",
      "-Wl,-rpath," <> lib,
      Path.join(t, "mainmiss.c"),
      "-o",
      app_bin
    ])

    # so relocation cannot resolve it
    File.rm!(Path.join(lib, "libmissing.dylib"))

    assert {:error, violations} = Orchestrator.Relocate.run(app, lib)
    assert Enum.any?(violations, &match?({:missing_lib, _, "@rpath/libmissing.dylib"}, &1))
  end

  test "relocate seeds enchant providers, bundles libenchant + SDK, provider dlopens with build libdir gone",
       %{t: t} do
    lib = Path.join(t, "buildlib")
    app = Path.join(t, "App.app")
    prefix = t

    # --- fixtures mimicking the conda enchant env layout (<prefix>/{lib,include,share}) ---
    # libsub stands in for the glib stack: a transitive dep of libenchant the walk must also pull.
    File.write!(Path.join(t, "sub.c"), "int sub(void){return 3;}\n")

    clang!([
      "-dynamiclib",
      "-install_name",
      "@rpath/libsub.dylib",
      "-Wl,-headerpad_max_install_names",
      Path.join(t, "sub.c"),
      "-o",
      Path.join(lib, "libsub.dylib")
    ])

    # libenchant-2.2.dylib depends on libsub.
    File.write!(Path.join(t, "ench.c"), "int sub(void); int ench(void){return sub()+1;}\n")

    clang!([
      "-dynamiclib",
      "-install_name",
      "@rpath/libenchant-2.2.dylib",
      "-Wl,-headerpad_max_install_names",
      "-L",
      lib,
      "-lsub",
      "-Wl,-rpath," <> lib,
      Path.join(t, "ench.c"),
      "-o",
      Path.join(lib, "libenchant-2.2.dylib")
    ])

    # A provider bundle in <lib>/enchant-2/, depending on libenchant. It is an ORPHAN: nothing
    # in the app links it, so relocate must SEED it for the closure walk to discover it.
    File.mkdir_p!(Path.join(lib, "enchant-2"))
    File.write!(Path.join(t, "prov.c"), "int ench(void); int prov(void){return ench();}\n")

    clang!([
      "-bundle",
      "-Wl,-headerpad_max_install_names",
      Path.join(lib, "libenchant-2.2.dylib"),
      Path.join(t, "prov.c"),
      "-o",
      Path.join([lib, "enchant-2", "enchant_fake.so"])
    ])

    # Non-Mach-O SDK payload sources (headers / pc / ordering / dict), env-relative to <lib>.
    File.mkdir_p!(Path.join([prefix, "include", "enchant-2"]))
    File.write!(Path.join([prefix, "include", "enchant-2", "enchant.h"]), "/* fixture */\n")
    File.mkdir_p!(Path.join(lib, "pkgconfig"))
    File.write!(Path.join([lib, "pkgconfig", "enchant-2.pc"]), "Name: enchant\n")
    File.mkdir_p!(Path.join([prefix, "share", "enchant-2"]))
    File.write!(Path.join([prefix, "share", "enchant-2", "enchant.ordering"]), "*:hunspell\n")
    File.mkdir_p!(Path.join([prefix, "share", "hunspell_dictionaries"]))
    File.write!(Path.join([prefix, "share", "hunspell_dictionaries", "en_US.aff"]), "SET UTF-8\n")
    File.write!(Path.join([prefix, "share", "hunspell_dictionaries", "en_US.dic"]), "1\nword\n")

    # The app needs at least one Mach-O executable.
    File.write!(Path.join(t, "main.c"), "int main(void){return 0;}\n")

    clang!([
      "-Wl,-headerpad_max_install_names",
      Path.join(t, "main.c"),
      "-o",
      Path.join(app, "Contents/MacOS/App")
    ])

    assert Orchestrator.Relocate.run(app, lib) == :ok

    # Providers seeded into Contents/lib/enchant-2 (Layout A).
    seeded = Path.join([app, "Contents", "lib", "enchant-2", "enchant_fake.so"])
    assert File.exists?(seeded)

    # libenchant + its transitive dep pulled into Frameworks by the existing closure walk.
    fw = Path.join([app, "Contents", "Frameworks"])
    assert File.exists?(Path.join(fw, "libenchant-2.2.dylib"))
    assert File.exists?(Path.join(fw, "libsub.dylib"))

    # -lenchant-2 link-name symlink for jinx's first-use compile.
    assert {:ok, "libenchant-2.2.dylib"} = File.read_link(Path.join(fw, "libenchant-2.dylib"))

    # Provider got a depth-correct rpath to reach Frameworks (Contents/lib/enchant-2 -> ../../Frameworks).
    assert "@loader_path/../../Frameworks" in Orchestrator.Macho.Otool.rpaths(seeded)

    # Non-Mach-O SDK payload bundled under Contents/Resources/enchant-sdk.
    sdk = Path.join([app, "Contents", "Resources", "enchant-sdk"])
    assert File.exists?(Path.join([sdk, "include", "enchant.h"]))
    assert File.exists?(Path.join([sdk, "enchant-2.pc"]))
    assert File.exists?(Path.join([sdk, "config", "hunspell", "en_US.aff"]))
    assert File.exists?(Path.join([sdk, "config", "hunspell", "en_US.dic"]))
    # Bundled ordering selects applespell first (then hunspell) for out-of-box macOS spell-check.
    assert File.read!(Path.join([sdk, "config", "enchant.ordering"])) =~ "applespell"

    # site-start.el (jinx wiring) shipped into the app's site-lisp (Emacs auto-loads it at startup).
    site_start = Path.join([app, "Contents", "Resources", "site-lisp", "site-start.el"])
    assert File.exists?(site_start)
    site_start_src = File.read!(site_start)
    assert site_start_src =~ "jinx--compile-flags"
    assert site_start_src =~ "ENCHANT_CONFIG_DIR"

    # Bundle remains validly signed after the enchant additions.
    assert {_, 0} =
             System.cmd("codesign", ["--verify", "--deep", "--strict", app],
               stderr_to_stdout: true
             )

    # Clean-machine proxy: with the build libdir gone, the seeded provider must still dlopen,
    # resolving libenchant + libsub from Frameworks via the rewritten rpaths.
    File.write!(Path.join(t, "probe.c"), """
    #include <dlfcn.h>
    #include <stdio.h>
    int main(int argc, char **argv) {
      void *h = dlopen(argv[1], RTLD_NOW);
      if (!h) { fprintf(stderr, "dlopen failed: %s", dlerror()); return 1; }
      return 0;
    }
    """)

    probe = Path.join(t, "probe")
    clang!([Path.join(t, "probe.c"), "-o", probe])

    File.rename!(lib, lib <> ".gone")
    assert {_, 0} = System.cmd(probe, [seeded], stderr_to_stdout: true)
  end
end
