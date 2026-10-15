const std = @import("std");
const g = @import("ghostty");

fn fuzz_one(_: void, smith: *std.testing.Smith) anyerror!void {
    var input_buf: [64 * 1024]u8 = undefined;
    const input = input_buf[0..smith.slice(&input_buf)];

    var terminal: g.GhosttyTerminal = undefined;
    const result = g.ghostty_terminal_new(null, &terminal, 80, 24);
    if (result != g.GHOSTTY_SUCCESS) return;
    defer g.ghostty_terminal_free(terminal);

    var max_scrollback_lines: usize = 100;
    if (g.ghostty_terminal_set(
        terminal,
        g.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
        &max_scrollback_lines,
    ) != g.GHOSTTY_SUCCESS) return;

    g.ghostty_terminal_vt_write(terminal, input.ptr, input.len);

    var state: g.GhosttyRenderState = undefined;
    if (g.ghostty_render_state_new(null, &state) == g.GHOSTTY_SUCCESS) {
        _ = g.ghostty_render_state_update(state, terminal);
        g.ghostty_render_state_free(state);
    }

    _ = g.ghostty_terminal_resize(terminal, 40, 12, 0, 0);

    g.ghostty_terminal_reset(terminal);
}

test "fuzz vt parser" {
    try std.testing.fuzz({}, fuzz_one, .{});
}
