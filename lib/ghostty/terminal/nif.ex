defmodule Ghostty.Terminal.Nif do
  @moduledoc false

  @version Mix.Project.config()[:version]

  # On Windows the NIF links libghostty-vt statically (ghostty-vt-static.lib).
  # The BEAM loads NIF DLLs without searching the NIF's own directory for
  # dependencies, so a dynamically linked ghostty-vt.dll would not be found
  # at runtime; a static link keeps the NIF self-contained.
  @ghostty_vt_lib (case :os.type() do
                     {:win32, _} -> "lib/ghostty-vt-static.lib"
                     {:unix, :darwin} -> "lib/libghostty-vt.dylib"
                     _ -> "lib/libghostty-vt.so"
                   end)

  use ZiglerPrecompiled,
    otp_app: :ghostty,
    base_url: "https://github.com/dannote/ghostty_ex/releases/download/v#{@version}",
    version: @version,
    force_build: System.get_env("GHOSTTY_BUILD") in ["1", "true"],
    targets: ~w(x86_64-linux-gnu aarch64-linux-gnu aarch64-macos-none x86_64-windows-gnu),
    zig_code_path: "ghostty_nif.zig",
    c: [
      headers: [c: "ghostty_nif.h"],
      include_dirs: [{:priv, "include"}],
      link_lib: [{:priv, @ghostty_vt_lib}]
    ],
    resources: [:TerminalResource, :TtyResource],
    nifs: [
      nif_new: 3,
      nif_set_color: 5,
      nif_set_palette: 2,
      nif_theme: 1,
      nif_vt_write: 2,
      nif_resize: 3,
      nif_reset: 1,
      nif_snapshot: [arity: 2, concurrency: :dirty_cpu],
      nif_scroll: 2,
      nif_get_cursor: 1,
      nif_set_effect_pid: 2,
      nif_encode_key: 6,
      nif_encode_mouse: 6,
      nif_encode_focus: 1,
      nif_render_cells: [arity: 1, concurrency: :dirty_cpu],
      nif_render_state: [arity: 1, concurrency: :dirty_cpu],
      nif_mouse_modes: 1,
      nif_scrollbar: 1,
      nif_focus_mode: 1,
      nif_tty_open: 2,
      nif_tty_write: 2,
      nif_tty_close: 1
    ]
end
