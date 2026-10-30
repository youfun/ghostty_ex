const beam = @import("beam");
const root = @import("root");
const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

/// Environment override passed to `nif_pty_open`. A `null` value unsets the
/// variable in the child; any other value sets it, replacing the inherited
/// value. Overrides are applied on top of the inherited environment.
pub const EnvKV = struct {
    []const u8,
    ?[]const u8,
};

fn send_data(owner: beam.pid, data: []const u8) void {
    const env = beam.alloc_env();
    beam.send(owner, .{ .pty_data, beam.make(data, .{ .env = env }) }, .{ .env = env }) catch {};
    beam.free_env(env);
}

fn send_exit_status(exit_code: i32, closed: *std.atomic.Value(bool), owner: beam.pid) void {
    if (!closed.load(.acquire)) {
        const env = beam.alloc_env();
        beam.send(owner, .{ .pty_exit, exit_code }, .{ .env = env }) catch {};
        beam.free_env(env);
    }
}

// Named `PtyData` at the root and `Data` inside each backend: a backend
// decl named `PtyData` would be an ambiguous reference while the root
// alias resolves to it.
const PtyData = if (is_windows) Windows.Data else Unix.Data;

pub const PtyResource = beam.Resource(PtyData, root, .{
    .Callbacks = PtyCallbacks,
});

pub const PtyCallbacks = struct {
    pub fn dtor(data: *PtyData) void {
        if (is_windows) {
            Windows.do_close(data);
        } else {
            Unix.do_close(data);
        }
    }
};

// ── Unix backend (forkpty) ──────────────────────────────────────────────

const Unix = struct {
    const c = @import("c");

    const Data = struct {
        master_fd: c_int,
        child_pid: c.pid_t,
        owner_pid: beam.pid,
        closed: std.atomic.Value(bool),
        thread: ?std.Thread,
    };

    fn do_close(data: *Data) void {
        const closed_ptr = @constCast(&data.closed);
        if (closed_ptr.swap(true, .acq_rel)) return;
        _ = c.kill(data.child_pid, c.SIGHUP);
        _ = c.close(data.master_fd);

        if (data.thread) |thread| {
            thread.join();
            data.thread = null;
        }

        _ = c.waitpid(data.child_pid, null, c.WNOHANG);
    }

    fn get_errno() c_int {
        if (comptime builtin.os.tag == .macos)
            return c.__error().*
        else
            return c.__errno_location().*;
    }

    fn is_would_block(errno: c_int) bool {
        return errno == c.EAGAIN or errno == c.EWOULDBLOCK;
    }

    fn wait_for_fd(fd: c_int, events: c_short, timeout_ms: c_int) c_short {
        var pfd: c.struct_pollfd = .{
            .fd = fd,
            .events = events,
            .revents = 0,
        };

        while (true) {
            const rc = c.poll(&pfd, 1, timeout_ms);

            if (rc > 0) return pfd.revents;
            if (rc == 0) return 0;
            if (get_errno() == c.EINTR) continue;
            return 0;
        }
    }

    fn send_unix_exit_status(status: c_int, closed: *std.atomic.Value(bool), owner: beam.pid) void {
        const exit_code: i32 = if (c.WIFEXITED(status)) c.WEXITSTATUS(status) else 0;
        send_exit_status(exit_code, closed, owner);
    }

    fn send_exit_and_wait(child_pid: c.pid_t, closed: *std.atomic.Value(bool), owner: beam.pid) void {
        var status: c_int = 0;

        var attempts: usize = 0;
        while (!closed.load(.acquire) and attempts < 100) : (attempts += 1) {
            const rc = c.waitpid(child_pid, &status, c.WNOHANG);
            if (rc == child_pid) {
                send_unix_exit_status(status, closed, owner);
                return;
            }
            if (rc < 0) {
                send_unix_exit_status(0, closed, owner);
                return;
            }
            var delay: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 1 * std.time.ns_per_ms };
            _ = c.nanosleep(&delay, null);
        }

        send_unix_exit_status(0, closed, owner);
    }

    fn send_exit_if_child_exited(child_pid: c.pid_t, closed: *std.atomic.Value(bool), owner: beam.pid) bool {
        var status: c_int = 0;
        const rc = c.waitpid(child_pid, &status, c.WNOHANG);
        if (rc == child_pid) {
            send_unix_exit_status(status, closed, owner);
            return true;
        }
        if (rc < 0) {
            send_unix_exit_status(0, closed, owner);
            return true;
        }
        return false;
    }

    fn reader_loop(master_fd: c_int, child_pid: c.pid_t, owner: beam.pid, closed: *std.atomic.Value(bool)) void {
        beam.independent_context(.{});
        defer beam.free_env(beam.context.env);

        var buf: [4096]u8 = undefined;

        const ready_env = beam.alloc_env();
        beam.send(owner, .{.pty_ready}, .{ .env = ready_env }) catch {};
        beam.free_env(ready_env);

        while (!closed.load(.acquire)) {
            const revents = wait_for_fd(master_fd, c.POLLIN | c.POLLHUP | c.POLLERR, 100);
            if (revents == 0) {
                if (send_exit_if_child_exited(child_pid, closed, owner)) return;
                continue;
            }

            if (revents & c.POLLIN != 0) {
                while (!closed.load(.acquire)) {
                    const n = c.read(master_fd, &buf, buf.len);

                    if (n > 0) {
                        send_data(owner, buf[0..@intCast(n)]);
                        continue;
                    }

                    if (n < 0) {
                        const errno = get_errno();
                        if (errno == c.EINTR) continue;
                        if (is_would_block(errno)) break;
                        if (errno == c.EIO) {
                            send_exit_and_wait(child_pid, closed, owner);
                            return;
                        }
                        return;
                    }

                    // n == 0: EOF
                    send_exit_and_wait(child_pid, closed, owner);
                    return;
                }
            }

            if (revents & (c.POLLHUP | c.POLLERR) != 0 and revents & c.POLLIN == 0) {
                send_exit_and_wait(child_pid, closed, owner);
                return;
            }
        }
    }

    fn open(cmd: []const u8, args: []const []const u8, cols: u16, rows: u16, cwd: []const u8, env: []const EnvKV, owner: beam.pid) !PtyResource {
        var ws: c.struct_winsize = .{
            .ws_col = cols,
            .ws_row = rows,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const cmd_z = try allocator.dupeZ(u8, cmd);
        const argv = try allocator.alloc(?[*:0]u8, args.len + 2);
        argv[0] = @ptrCast(cmd_z.ptr);

        for (args, 0..) |arg, i| {
            const arg_z = try allocator.dupeZ(u8, arg);
            argv[i + 1] = @ptrCast(arg_z.ptr);
        }

        argv[args.len + 1] = null;

        // Prepare envp and PATH candidates before fork. setenv/unsetenv and
        // allocation are unsafe in the forked child of a multithreaded VM.
        const cwd_z: ?[*:0]u8 = if (cwd.len > 0) try allocator.dupeZ(u8, cwd) else null;
        var entries = std.ArrayList([:0]u8).empty;
        const inherited = c.ghostty_environ();
        var env_index: usize = 0;
        while (inherited[env_index] != null) : (env_index += 1) {
            try entries.append(allocator, try allocator.dupeZ(u8, std.mem.span(inherited[env_index])));
        }
        for (env) |kv| {
            var i: usize = 0;
            while (i < entries.items.len) {
                const key = std.mem.sliceTo(entries.items[i], '=');
                if (std.mem.eql(u8, key, kv[0])) {
                    _ = entries.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
            if (kv[1]) |value| {
                try entries.append(allocator, try std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ kv[0], value }, 0));
            }
        }
        const envp = try allocator.alloc(?[*:0]u8, entries.items.len + 1);
        var path: []const u8 = "/usr/bin:/bin";
        for (entries.items, 0..) |entry, i| {
            envp[i] = entry.ptr;
            if (std.mem.startsWith(u8, entry, "PATH=")) path = entry[5..];
        }
        envp[entries.items.len] = null;

        var candidates = std.ArrayList([:0]u8).empty;
        if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
            try candidates.append(allocator, cmd_z);
        } else {
            var dirs = std.mem.splitScalar(u8, path, ':');
            while (dirs.next()) |dir| {
                const candidate = if (dir.len == 0) cmd_z else try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, cmd }, 0);
                try candidates.append(allocator, candidate);
            }
        }
        // execvp-compatible fallback for executable scripts without a shebang.
        const shell_argv = try allocator.alloc(?[*:0]u8, args.len + 3);
        shell_argv[0] = @constCast(@as([*:0]const u8, "/bin/sh"));
        for (argv[1 .. args.len + 2], 2..) |arg, i| shell_argv[i] = arg;

        // SAFETY: initialized by forkpty below
        var master_fd: c_int = undefined;
        const pid = c.forkpty(&master_fd, null, null, &ws);
        if (pid < 0) return error.forkpty_failed;

        if (pid == 0) {
            if (cwd_z) |dir| {
                if (c.chdir(dir) != 0) c._exit(127);
            }

            for (candidates.items) |candidate| {
                _ = c.execve(candidate.ptr, @ptrCast(argv.ptr), @ptrCast(envp.ptr));
                const errno = get_errno();
                if (errno == c.ENOEXEC) {
                    shell_argv[1] = candidate.ptr;
                    _ = c.execve("/bin/sh", @ptrCast(shell_argv.ptr), @ptrCast(envp.ptr));
                    c._exit(127);
                }
                if (errno != c.ENOENT and errno != c.ENOTDIR and errno != c.EACCES) break;
            }
            c._exit(127);
        }

        var owns_child = true;
        errdefer if (owns_child) {
            _ = c.kill(pid, c.SIGKILL);
            _ = c.close(master_fd);
            while (c.waitpid(pid, null, 0) < 0 and get_errno() == c.EINTR) {}
        };

        const flags = c.fcntl(master_fd, c.F_GETFL);
        _ = c.fcntl(master_fd, c.F_SETFL, flags | @as(c_int, c.O_NONBLOCK));

        const res = try PtyResource.create(.{
            .master_fd = master_fd,
            .child_pid = pid,
            .owner_pid = owner,
            .closed = std.atomic.Value(bool).init(false),
            .thread = null,
        }, .{});

        owns_child = false;
        errdefer res.release();

        const data = res.__payload;
        const closed_ptr = @constCast(&data.closed);
        const thread = std.Thread.spawn(.{}, reader_loop, .{ master_fd, pid, owner, closed_ptr }) catch {
            // No reader exists to reap the child on this error path.
            data.closed.store(true, .release);
            _ = c.kill(pid, c.SIGKILL);
            _ = c.close(master_fd);
            while (c.waitpid(pid, null, 0) < 0 and get_errno() == c.EINTR) {}
            return error.thread_spawn_failed;
        };
        data.thread = thread;

        return res;
    }

    fn write(pty: *Data, data: []const u8) void {
        if (pty.closed.load(.acquire)) return;

        var off: usize = 0;
        while (off < data.len and !pty.closed.load(.acquire)) {
            const n = c.write(pty.master_fd, data.ptr + off, data.len - off);

            if (n > 0) {
                off += @intCast(n);
                continue;
            }

            if (n < 0) {
                const errno = get_errno();
                if (errno == c.EINTR) continue;

                if (is_would_block(errno)) {
                    _ = wait_for_fd(pty.master_fd, c.POLLOUT, 100);
                    continue;
                }
            }

            break;
        }
    }

    fn resize(pty: *Data, cols: u16, rows: u16) void {
        if (pty.closed.load(.acquire)) return;

        var ws: c.struct_winsize = .{
            .ws_col = cols,
            .ws_row = rows,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = c.ioctl(pty.master_fd, c.TIOCSWINSZ, &ws);
        _ = c.kill(pty.child_pid, c.SIGWINCH);
    }
};

// ── Windows backend (anonymous pipes) ───────────────────────────────────
//
// This backend wires stdin/stdout/stderr to anonymous pipes through
// STARTF_USESTDHANDLES. The child runs without a console (CREATE_NO_WINDOW).
// Programs using stdio can exchange data, but console APIs, terminal input
// events and child resizing are unavailable. In particular cmd.exe does
// not echo input or print an interactive prompt.

const Windows = struct {
    const w = std.os.windows;
    const k32 = w.kernel32;

    const WAIT_OBJECT_0: w.DWORD = 0;
    const HANDLE_FLAG_INHERIT: w.DWORD = 0x00000001;

    extern "kernel32" fn CreatePipe(hReadPipe: *w.HANDLE, hWritePipe: *w.HANDLE, lpPipeAttributes: ?*w.SECURITY_ATTRIBUTES, nSize: w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn SetHandleInformation(hObject: w.HANDLE, dwMask: w.DWORD, dwFlags: w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn PeekNamedPipe(hNamedPipe: w.HANDLE, lpBuffer: ?*anyopaque, nBufferSize: w.DWORD, lpBytesRead: ?*w.DWORD, lpTotalBytesAvail: ?*w.DWORD, lpBytesLeftThisMessage: ?*w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn Sleep(dwMilliseconds: w.DWORD) callconv(.winapi) void;
    extern "kernel32" fn ReadFile(hFile: w.HANDLE, lpBuffer: w.LPVOID, nNumberOfBytesToRead: w.DWORD, lpNumberOfBytesRead: ?*w.DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) w.BOOL;
    extern "kernel32" fn WriteFile(hFile: w.HANDLE, lpBuffer: *const anyopaque, nNumberOfBytesToWrite: w.DWORD, lpNumberOfBytesWritten: ?*w.DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) w.BOOL;
    extern "kernel32" fn WaitForSingleObject(hHandle: w.HANDLE, dwMilliseconds: w.DWORD) callconv(.winapi) w.DWORD;
    extern "kernel32" fn GetExitCodeProcess(hProcess: w.HANDLE, lpExitCode: *w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn TerminateProcess(hProcess: w.HANDLE, uExitCode: w.UINT) callconv(.winapi) w.BOOL;
    extern "kernel32" fn CompareStringOrdinal(lpString1: [*]const u16, cchCount1: c_int, lpString2: [*]const u16, cchCount2: c_int, bIgnoreCase: w.BOOL) callconv(.winapi) c_int;
    extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*:0]w.WCHAR;
    extern "kernel32" fn FreeEnvironmentStringsW(lpszEnvironmentStrings: [*:0]w.WCHAR) callconv(.winapi) w.BOOL;

    const Data = struct {
        in_write: w.HANDLE,
        out_read: w.HANDLE,
        process: w.HANDLE,
        thread_handle: w.HANDLE,
        owner_pid: beam.pid,
        closed: std.atomic.Value(bool),
        thread: ?std.Thread,
    };

    fn open(cmd: []const u8, args: []const []const u8, cols: u16, rows: u16, cwd: []const u8, env: []const EnvKV, owner: beam.pid) !PtyResource {
        // Pipes have no window size; the VT side tracks cols/rows.
        _ = cols;
        _ = rows;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Both pipes are inheritable so the child receives its std handles.
        var sa = w.SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(w.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = null,
            .bInheritHandle = .TRUE,
        };

        var child_stdin: ?w.HANDLE = null;
        var in_write: ?w.HANDLE = null;
        var out_read: ?w.HANDLE = null;
        var child_stdout: ?w.HANDLE = null;
        var pi: ?w.PROCESS.INFORMATION = null;

        errdefer {
            if (pi) |p| {
                _ = TerminateProcess(p.hProcess, 1);
                _ = WaitForSingleObject(p.hProcess, 1_000);
                w.CloseHandle(p.hProcess);
                w.CloseHandle(p.hThread);
            }
            if (child_stdin) |h| w.CloseHandle(h);
            if (child_stdout) |h| w.CloseHandle(h);
            if (in_write) |h| w.CloseHandle(h);
            if (out_read) |h| w.CloseHandle(h);
        }

        // Input pipe: the client writes keystrokes to in_write and the
        // child reads them from child_stdin. Output pipe: the child writes
        // to child_stdout and the client reads from out_read.
        var stdin_read: w.HANDLE = undefined;
        var stdin_write: w.HANDLE = undefined;
        if (CreatePipe(&stdin_read, &stdin_write, &sa, 0) == .FALSE)
            return error.create_pipe_failed;
        child_stdin = stdin_read;
        in_write = stdin_write;
        if (SetHandleInformation(stdin_write, HANDLE_FLAG_INHERIT, 0) == .FALSE)
            return error.set_handle_info_failed;

        var stdout_read: w.HANDLE = undefined;
        var stdout_write: w.HANDLE = undefined;
        if (CreatePipe(&stdout_read, &stdout_write, &sa, 0) == .FALSE)
            return error.create_pipe_failed;
        out_read = stdout_read;
        child_stdout = stdout_write;
        if (SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0) == .FALSE)
            return error.set_handle_info_failed;

        const cmdline = try build_command_line(allocator, cmd, args);
        const cmdline_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, cmdline);
        const env_block = try build_env_block(allocator, env);
        const cwd_w: ?w.LPCWSTR =
            if (cwd.len > 0) try std.unicode.utf8ToUtf16LeAllocZ(allocator, cwd) else null;

        var si = std.mem.zeroes(w.STARTUPINFOW);
        si.cb = @sizeOf(w.STARTUPINFOW);
        si.dwFlags = w.STARTF_USESTDHANDLES;
        si.hStdInput = child_stdin;
        si.hStdOutput = child_stdout;
        si.hStdError = child_stdout; // stderr is merged into stdout

        var pi_val = std.mem.zeroes(w.PROCESS.INFORMATION);
        // CREATE_NO_WINDOW keeps the console-less child from popping a
        // console window or inheriting the parent's console; stdio is fully
        // redirected to the pipes. CREATE_UNICODE_ENVIRONMENT is required
        // when an env block is passed.
        const created = k32.CreateProcessW(
            null,
            cmdline_w,
            null,
            null,
            w.BOOL.TRUE,
            .{
                .create_no_window = true,
                .create_unicode_environment = env_block != null,
            },
            env_block,
            cwd_w,
            &si,
            &pi_val,
        );

        // The child owns its ends of both pipes now.
        if (child_stdin) |h| {
            w.CloseHandle(h);
            child_stdin = null;
        }
        if (child_stdout) |h| {
            w.CloseHandle(h);
            child_stdout = null;
        }

        if (created == .FALSE) return error.create_process_failed;
        pi = pi_val;

        const res = try PtyResource.create(.{
            .in_write = in_write.?,
            .out_read = out_read.?,
            .process = pi.?.hProcess,
            .thread_handle = pi.?.hThread,
            .owner_pid = owner,
            .closed = std.atomic.Value(bool).init(false),
            .thread = null,
        }, .{});

        // The resource now owns the handles. On failure its destructor is
        // the only cleanup path, avoiding double closes of recycled handles.
        in_write = null;
        out_read = null;
        pi = null;
        errdefer res.release();

        const data = res.__payload;
        const thread = std.Thread.spawn(.{}, reader_loop, .{data}) catch
            return error.thread_spawn_failed;
        data.thread = thread;

        return res;
    }

    fn reader_loop(data: *Data) void {
        beam.independent_context(.{});
        defer beam.free_env(beam.context.env);

        var buf: [4096]u8 = undefined;
        var exit_remaining: ?w.DWORD = null;

        const ready_env = beam.alloc_env();
        beam.send(data.owner_pid, .{.pty_ready}, .{ .env = ready_env }) catch {};
        beam.free_env(ready_env);

        while (!data.closed.load(.acquire)) {
            // Only this thread reads the pipe. Reading at most the available
            // bytes cannot wait for descendants to close inherited stdout.
            const exited = WaitForSingleObject(data.process, 0) == WAIT_OBJECT_0;
            var available: w.DWORD = 0;
            if (PeekNamedPipe(data.out_read, null, 0, null, &available, null) == .FALSE) break;
            // Drain only what was queued when the direct child exited, even
            // if descendants keep writing to their inherited stdout.
            if (exited and exit_remaining == null) exit_remaining = available;
            if (exit_remaining) |remaining| {
                if (remaining == 0) break;
                available = @min(available, remaining);
            }
            if (available == 0) {
                Sleep(10);
                continue;
            }

            var bytes: w.DWORD = 0;
            const ok = ReadFile(data.out_read, &buf, @min(available, buf.len), &bytes, null);
            if (ok == .FALSE) break; // broken pipe: the child closed its stdout
            if (bytes == 0) continue;
            if (exit_remaining) |remaining| exit_remaining = remaining - bytes;
            send_data(data.owner_pid, buf[0..bytes]);
        }

        send_exit_and_wait(data);
    }

    fn send_exit_and_wait(data: *Data) void {
        if (data.closed.load(.acquire)) return;

        // A process can close stdout and keep running. Report its status
        // only once it exits, while allowing close to stop this wait.
        while (!data.closed.load(.acquire)) {
            if (WaitForSingleObject(data.process, 100) != WAIT_OBJECT_0) continue;
            var code: w.DWORD = 0;
            if (GetExitCodeProcess(data.process, &code) != .FALSE) {
                send_exit_status(@bitCast(code), &data.closed, data.owner_pid);
            }
            return;
        }
    }

    fn do_close(data: *Data) void {
        const closed_ptr = @constCast(&data.closed);
        if (closed_ptr.swap(true, .acq_rel)) return;

        // Closing the input pipe gives the child EOF on stdin.
        w.CloseHandle(data.in_write);

        // The direct child does not always exit on EOF, so terminate it
        // after a grace period. Descendant processes are not terminated.
        if (WaitForSingleObject(data.process, 1_000) != WAIT_OBJECT_0) {
            _ = TerminateProcess(data.process, 1);
            _ = WaitForSingleObject(data.process, 1_000);
        }

        // The reader polls closed, so joining does not depend on descendants
        // releasing inherited stdout handles.
        if (data.thread) |thread| {
            thread.join();
            data.thread = null;
        }

        w.CloseHandle(data.out_read);
        w.CloseHandle(data.process);
        w.CloseHandle(data.thread_handle);
    }

    fn write_all(data: *Data, bytes: []const u8) bool {
        var off: usize = 0;
        while (off < bytes.len and !data.closed.load(.acquire)) {
            var written: w.DWORD = 0;
            const ok = WriteFile(data.in_write, bytes.ptr + off, @intCast(bytes.len - off), &written, null);
            if (ok == .FALSE or written == 0) return false; // broken pipe: the child is gone
            off += written;
        }
        return true;
    }

    fn write(data: *Data, bytes: []const u8) void {
        if (data.closed.load(.acquire)) return;

        // Translate bare CR to CRLF so terminal Enter keystrokes ("\r")
        // complete a line on Windows pipes, matching Unix PTY ICRNL.
        var start: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            if (bytes[i] == '\r' and (i + 1 >= bytes.len or bytes[i + 1] != '\n')) {
                if (!write_all(data, bytes[start..i])) return;
                if (!write_all(data, "\r\n")) return;
                start = i + 1;
            }
        }
        if (start < bytes.len) {
            _ = write_all(data, bytes[start..]);
        }
    }

    fn resize(data: *Data, cols: u16, rows: u16) void {
        _ = data;
        _ = cols;
        _ = rows;
        // Pipes have no window size to report; the VT side tracks cols/rows.
    }

    // Builds a Windows command line from cmd + args using the MSVCRT quoting
    // rules that CreateProcessW consumers parse.
    fn build_command_line(allocator: std.mem.Allocator, cmd: []const u8, args: []const []const u8) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        try append_quoted(allocator, &out, cmd);

        for (args) |arg| {
            try out.append(allocator, ' ');
            try append_quoted(allocator, &out, arg);
        }

        return out.toOwnedSlice(allocator);
    }

    fn append_quoted(allocator: std.mem.Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
        if (arg.len == 0) {
            try out.appendSlice(allocator, "\"\"");
            return;
        }

        var needs_quotes = false;
        for (arg) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '"') {
                needs_quotes = true;
                break;
            }
        }

        if (!needs_quotes) {
            try out.appendSlice(allocator, arg);
            return;
        }

        try out.append(allocator, '"');
        var backslashes: usize = 0;
        for (arg) |ch| {
            if (ch == '\\') {
                backslashes += 1;
                continue;
            }
            if (ch == '"') {
                try out.appendNTimes(allocator, '\\', backslashes * 2 + 1);
                try out.append(allocator, '"');
            } else {
                try out.appendNTimes(allocator, '\\', backslashes);
                try out.append(allocator, ch);
            }
            backslashes = 0;
        }
        try out.appendNTimes(allocator, '\\', backslashes * 2);
        try out.append(allocator, '"');
    }

    // Builds a UTF-16 environment block for CreateProcessW. The block starts
    // from the inherited environment (so SystemRoot and friends survive) and
    // applies the requested overrides. Returns null when there is nothing to
    // change, in which case the child inherits the environment as-is.
    fn build_env_block(allocator: std.mem.Allocator, env: []const EnvKV) !?[*:0]const u16 {
        if (env.len == 0) return null;

        const inherited = GetEnvironmentStringsW() orelse return error.get_environment_strings_failed;
        defer _ = FreeEnvironmentStringsW(inherited);

        var entries = std.ArrayList([]const u16).empty;
        defer entries.deinit(allocator);

        var cursor: [*:0]const w.WCHAR = inherited;
        while (cursor[0] != 0) {
            const entry = std.mem.span(cursor);
            // Preserve per-drive working-directory entries as well.
            try entries.append(allocator, entry);
            cursor += entry.len + 1;
        }

        for (env) |kv| {
            const key = try std.unicode.utf8ToUtf16LeAlloc(allocator, kv[0]);
            var i: usize = 0;
            while (i < entries.items.len) {
                if (compare_env_keys(env_key(entries.items[i]), key) == 2) {
                    _ = entries.swapRemove(i);
                } else {
                    i += 1;
                }
            }

            if (kv[1]) |value| {
                const entry = try std.fmt.allocPrint(allocator, "{s}={s}", .{ kv[0], value });
                try entries.append(allocator, try std.unicode.utf8ToUtf16LeAlloc(allocator, entry));
            }
        }

        // Environment blocks must be sorted by name, case-insensitively.
        std.mem.sort([]const u16, entries.items, {}, env_entry_less);

        var block = std.ArrayList(u16).empty;
        for (entries.items) |entry| {
            try block.appendSlice(allocator, entry);
            try block.append(allocator, 0);
        }
        if (block.items.len == 0) try block.append(allocator, 0);
        const slice = try block.toOwnedSliceSentinel(allocator, 0);

        return slice.ptr;
    }

    fn env_key(entry: []const u16) []const u16 {
        // Hidden drive entries have a name such as "=C:".
        const start: usize = if (entry.len > 0 and entry[0] == '=') 1 else 0;
        const eq = std.mem.indexOfScalarPos(u16, entry, start, '=') orelse entry.len;
        return entry[0..eq];
    }

    fn compare_env_keys(a: []const u16, b: []const u16) c_int {
        return CompareStringOrdinal(a.ptr, @intCast(a.len), b.ptr, @intCast(b.len), .TRUE);
    }

    fn env_entry_less(_: void, a: []const u16, b: []const u16) bool {
        return compare_env_keys(env_key(a), env_key(b)) == 1;
    }
};

// ── NIF entry points ────────────────────────────────────────────────────

pub fn nif_pty_open(cmd: []const u8, args: []const []const u8, cols: u16, rows: u16, cwd: []const u8, env: []const EnvKV, owner: beam.pid) !PtyResource {
    if (cmd.len == 0 or std.mem.indexOfScalar(u8, cmd, 0) != null or
        std.mem.indexOfScalar(u8, cwd, 0) != null) return error.invalid_command_or_cwd;
    for (args) |arg| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.invalid_argument;
    }
    for (env) |kv| {
        if (kv[0].len == 0 or std.mem.indexOfAny(u8, kv[0], "=\x00") != null) return error.invalid_env_name;
        if (kv[1]) |value| {
            if (std.mem.indexOfScalar(u8, value, 0) != null) return error.invalid_env_value;
        }
    }

    if (is_windows) {
        return Windows.open(cmd, args, cols, rows, cwd, env, owner);
    }

    return Unix.open(cmd, args, cols, rows, cwd, env, owner);
}

pub fn nif_pty_write(res: PtyResource, data: []const u8) void {
    const pty = res.__payload;
    if (is_windows) {
        Windows.write(pty, data);
    } else {
        Unix.write(pty, data);
    }
}

pub fn nif_pty_resize(res: PtyResource, cols: u16, rows: u16) void {
    const pty = res.__payload;
    if (is_windows) {
        Windows.resize(pty, cols, rows);
    } else {
        Unix.resize(pty, cols, rows);
    }
}

pub fn nif_pty_close(res: PtyResource) void {
    if (is_windows) {
        Windows.do_close(res.__payload);
    } else {
        Unix.do_close(res.__payload);
    }
}
