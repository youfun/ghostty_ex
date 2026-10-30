defmodule Mix.Tasks.Ghostty.Setup do
  @shortdoc "Build libghostty-vt and install into priv/"

  @moduledoc """
  Clones the Ghostty source, builds libghostty-vt, and installs the
  shared library and headers into `priv/`.

  This only needs to run once. After that, `GHOSTTY_BUILD=1 mix compile`
  will find the library in `priv/` and build the NIF from source.

  Set `GHOSTTY_SOURCE_DIR` to skip cloning and use a local checkout.

  ## Examples

      mix ghostty.setup
      GHOSTTY_SOURCE_DIR=~/code/ghostty mix ghostty.setup

  """

  use Mix.Task

  @ghostty_repo "https://github.com/ghostty-org/ghostty.git"
  @ghostty_ref_file ".ghostty-ref"

  @impl true
  def run(_args) do
    source_dir = source_dir()
    ensure_source(source_dir)
    build(source_dir)
    install(source_dir)
    install_to_build()
    Mix.shell().info("Done. Run: GHOSTTY_BUILD=1 mix compile")
  end

  defp source_dir do
    System.get_env("GHOSTTY_SOURCE_DIR") ||
      Path.join(System.tmp_dir!(), "ghostty-src")
  end

  defp ensure_source(dir) do
    if System.get_env("GHOSTTY_SOURCE_DIR") do
      unless File.dir?(dir) do
        Mix.raise("GHOSTTY_SOURCE_DIR=#{dir} does not exist")
      end

      Mix.shell().info("Using local Ghostty source: #{dir}")
    else
      if File.dir?(Path.join(dir, ".git")) do
        sync_source(dir)
      else
        ref = ghostty_ref()
        Mix.shell().info("Cloning ghostty (#{short_ref(ref)})...")
        cmd!("git", ["init", dir])
        cmd!("git", ["-C", dir, "remote", "add", "origin", @ghostty_repo])
        cmd!("git", ["-C", dir, "fetch", "--depth", "1", "origin", ref])
        cmd!("git", ["-C", dir, "checkout", "--detach", "FETCH_HEAD"])
      end
    end
  end

  defp sync_source(dir) do
    ref = ghostty_ref()
    current_ref = cmd_output!("git", ["-C", dir, "rev-parse", "HEAD"])

    if current_ref == ref do
      Mix.shell().info("Ghostty source already at #{short_ref(ref)} in #{dir}")
    else
      source_dirty? =
        cmd_output!("git", ["-C", dir, "status", "--porcelain", "--untracked-files=no"]) != ""

      if source_dirty? do
        Mix.raise("cannot update modified Ghostty source at #{dir}; commit or discard its tracked changes first")
      end

      Mix.shell().info("Updating Ghostty source to #{short_ref(ref)} in #{dir}...")
      cmd!("git", ["-C", dir, "fetch", "--depth", "1", "origin", ref])
      cmd!("git", ["-C", dir, "checkout", "--detach", "FETCH_HEAD"])
    end
  end

  defp build(source_dir) do
    zig_out = Path.join(source_dir, "zig-out")
    build_ref_file = Path.join(zig_out, ".ghostty-ex-ref")
    source_ref = cmd_output!("git", ["-C", source_dir, "rev-parse", "HEAD"])
    zig_version = cmd_output!("zig", ["version"])
    host = :erlang.system_info(:system_architecture)
    build_stamp = Enum.join([source_ref, zig_version, host], "\n")
    source_dirty? = cmd_output!("git", ["-C", source_dir, "status", "--porcelain", "--untracked-files=no"]) != ""
    built_ref = File.read(build_ref_file)

    if File.dir?(Path.join(zig_out, "lib")) and not source_dirty? and built_ref == {:ok, build_stamp} do
      Mix.shell().info("libghostty-vt already built for #{short_ref(source_ref)} with Zig #{zig_version}")
    else
      File.rm_rf!(zig_out)
      Mix.shell().info("Building libghostty-vt (#{short_ref(source_ref)}, Zig #{zig_version})...")
      cmd!("zig", ["build", "-Demit-lib-vt", "-Doptimize=ReleaseFast"], cd: source_dir)
      unless source_dirty?, do: File.write!(build_ref_file, build_stamp)
    end
  end

  defp install(source_dir) do
    zig_out = Path.join(source_dir, "zig-out")
    priv_dir = Path.join(project_root(), "priv")
    lib_dir = Path.join(priv_dir, "lib")
    include_dir = Path.join(priv_dir, "include")

    File.mkdir_p!(lib_dir)

    # Mix may link the build priv directory to this directory, so NIFs can
    # live here too. Replace only the VT library artifacts.
    for file <- File.ls!(lib_dir), String.contains?(file, "ghostty-vt") do
      File.rm!(Path.join(lib_dir, file))
    end

    File.rm_rf!(include_dir)
    File.mkdir_p!(include_dir)

    copy_libs(Path.join(zig_out, "lib"), lib_dir)
    # On Windows zig installs the DLL into bin/ while lib/ holds the import
    # library (ghostty-vt.lib) and the static library. The NIF links the
    # static library (see terminal/nif.ex), so both artifacts are installed.
    if windows?(), do: copy_libs(Path.join(zig_out, "bin"), lib_dir)
    copy_include_tree(Path.join([zig_out, "include", "ghostty"]), Path.join(include_dir, "ghostty"))
    fix_dylib_install_name(lib_dir)
  end

  defp install_to_build do
    src_priv = Path.join(project_root(), "priv")

    # The app path also follows custom MIX_BUILD_PATH locations.
    dest_privs =
      [
        Path.join(Mix.Project.app_path(), "priv"),
        Path.join([project_root(), "_build", "dev", "lib", "ghostty", "priv"]),
        Path.join([project_root(), "_build", "test", "lib", "ghostty", "priv"])
      ]
      |> Enum.uniq()

    for dest_priv <- dest_privs, separate_priv?(src_priv, dest_priv) do
      dest_lib = Path.join(dest_priv, "lib")
      dest_include = Path.join(dest_priv, "include")

      File.mkdir_p!(dest_lib)
      File.mkdir_p!(dest_include)

      # Replace only the libghostty-vt artifacts. The compiled NIF binaries
      # live in the same lib directory and must survive a re-run of this
      # task; wiping the whole priv dir would leave them unloaded until a
      # forced recompile.
      for file <- File.ls!(dest_lib), String.contains?(file, "ghostty-vt") do
        File.rm!(Path.join(dest_lib, file))
      end

      copy_libs(Path.join(src_priv, "lib"), dest_lib)
      copy_include_tree(Path.join(src_priv, "include"), dest_include)
      fix_dylib_install_name(dest_lib)
    end

    if windows?(), do: install_zigler_win_headers(src_priv)
  end

  # zigler 0.16.0 on Hex omits priv/erl_nif_win from its package files.
  # Seed the compatibility headers into zigler's priv dir so translate-c succeeds.
  defp install_zigler_win_headers(src_priv) do
    win_headers = Path.join(src_priv, "erl_nif_win")

    if File.dir?(win_headers) do
      zigler_privs =
        [
          case :code.priv_dir(:zigler) do
            {:error, _} -> nil
            priv -> List.to_string(priv)
          end,
          Path.join([project_root(), "deps", "zigler", "priv"]),
          Path.join([Mix.Project.deps_path(), "zigler", "priv"]),
          Path.join([Mix.Project.build_path(), "lib", "zigler", "priv"])
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      for zigler_priv <- zigler_privs, File.dir?(Path.dirname(zigler_priv)) do
        dest = Path.join(zigler_priv, "erl_nif_win")
        File.mkdir_p!(dest)
        File.cp_r!(win_headers, dest)
      end
    end
  end

  defp copy_libs(src_dir, dest_dir) do
    src_dir
    |> File.ls!()
    |> Enum.filter(fn file ->
      src = Path.join(src_dir, file)
      shared_lib?(file) and File.regular?(src)
    end)
    |> Enum.each(fn file ->
      src = Path.join(src_dir, file)
      dest = Path.join(dest_dir, file)
      File.cp!(src, dest)
      Mix.shell().info("  #{dest}")
    end)
  end

  # The shared library ships on every platform. On Windows the NIF links
  # libghostty-vt statically, so the static library ships too; the import
  # library (ghostty-vt.lib) and debug symbols (.pdb) stay behind.
  defp shared_lib?(file) do
    case :os.type() do
      {:win32, _} -> file in ["ghostty-vt.dll", "ghostty-vt-static.lib"]
      {:unix, :darwin} -> String.contains?(file, "libghostty-vt") and String.ends_with?(file, ".dylib")
      _ -> String.contains?(file, "libghostty-vt") and String.ends_with?(file, ".so")
    end
  end

  defp windows?, do: match?({:win32, _}, :os.type())

  defp separate_priv?(src, dest) do
    Path.expand(src) != Path.expand(dest) and
      case File.lstat(dest) do
        {:ok, %{type: :symlink}} -> false
        _ -> true
      end
  end

  defp copy_include_tree(src, dest) do
    unless File.dir?(src) do
      Mix.raise("missing include directory: #{src}")
    end

    File.rm_rf!(dest)
    File.mkdir_p!(Path.dirname(dest))
    File.cp_r!(src, dest)
    Mix.shell().info("  #{dest}/")
  end

  defp fix_dylib_install_name(lib_dir) do
    case :os.type() do
      {:unix, :darwin} ->
        dylib = Path.join(lib_dir, "libghostty-vt.dylib")
        absolute_id = Path.expand(dylib)

        for file <- File.ls!(lib_dir), String.ends_with?(file, ".dylib") do
          path = Path.join(lib_dir, file)
          System.cmd("install_name_tool", ["-id", absolute_id, path], stderr_to_stdout: true)
        end

      _ ->
        :ok
    end
  end

  defp cmd!(cmd, args, opts \\ []) do
    {output, status} = System.cmd(cmd, args, [{:stderr_to_stdout, true} | opts])

    if status != 0 do
      Mix.raise("#{cmd} #{Enum.join(args, " ")} failed:\n#{output}")
    end
  end

  defp cmd_output!(cmd, args) do
    {output, status} = System.cmd(cmd, args, stderr_to_stdout: true)

    if status != 0 do
      Mix.raise("#{cmd} #{Enum.join(args, " ")} failed:\n#{output}")
    end

    String.trim(output)
  end

  defp project_root do
    Mix.Project.project_file()
    |> Path.dirname()
  end

  defp ghostty_ref do
    project_root()
    |> Path.join(@ghostty_ref_file)
    |> File.read!()
    |> String.trim()
  end

  defp short_ref(ref), do: String.slice(ref, 0, 7)
end
