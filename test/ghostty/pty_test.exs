defmodule Ghostty.PTYTest do
  use ExUnit.Case, async: false

  @pty_event_timeout_ms 3_000
  @poll_interval_ms 20

  @windows? match?({:win32, _}, :os.type())

  describe "start_link/1" do
    test "captures command output" do
      {cmd, args} = print_command("hello_from_pty")
      {:ok, pty} = Ghostty.PTY.start_link(cmd: cmd, args: args)

      data = wait_until_output("hello_from_pty")
      assert data =~ "hello_from_pty"
      assert_close(pty)
    end

    test "writes to child stdin" do
      {cmd, args} = echo_command()
      {:ok, pty} = Ghostty.PTY.start_link(cmd: cmd, args: args)

      Ghostty.PTY.write(pty, "echo_this\r")
      data = wait_until_output("echo_this")
      assert data =~ "echo_this"
      assert_close(pty)
    end

    test "reports exit after short output-only commands" do
      for _ <- 1..50 do
        {cmd, args} = print_command("ok")
        {:ok, pty} = Ghostty.PTY.start_link(cmd: cmd, args: args)
        assert_receive {:data, data}, @pty_event_timeout_ms
        assert data =~ "ok"
        assert_receive {:exit, 0}, @pty_event_timeout_ms
        assert_close(pty)
      end
    end

    if @windows? do
      @tag skip: "Windows PTY backend uses anonymous pipes rather than a console TTY"
    end

    test "child sees a real TTY" do
      {:ok, pty} =
        Ghostty.PTY.start_link(
          cmd: "/usr/bin/python3",
          args: [
            "-c",
            "import os, sys, time; print('tty' if os.isatty(0) else 'not_tty'); sys.stdout.flush(); time.sleep(0.2)"
          ]
        )

      data = wait_until_output("tty")
      assert data =~ "tty"
      refute data =~ "not_tty"
      assert_close(pty)
    end

    @tag :tmp_dir
    test "starts child in the requested working directory", %{tmp_dir: tmp_dir} do
      {cmd, args} = pwd_command()
      {:ok, pty} = Ghostty.PTY.start_link(cmd: cmd, args: args, cwd: tmp_dir)

      expected = Path.basename(tmp_dir)
      data = wait_until_output(expected)
      assert data =~ expected
      assert_close(pty)
    end

    test "applies env overrides and unsets nil entries" do
      System.put_env("GHOSTTY_PTY_INHERITED", "from_parent")
      System.put_env("GHOSTTY_PTY_REMOVED", "remove_me")

      on_exit(fn ->
        System.delete_env("GHOSTTY_PTY_INHERITED")
        System.delete_env("GHOSTTY_PTY_REMOVED")
      end)

      {cmd, args} = env_probe_command()

      {:ok, pty} =
        Ghostty.PTY.start_link(
          cmd: cmd,
          args: args,
          env: [
            {"GHOSTTY_PTY_ADDED", "added_val"},
            {"GHOSTTY_PTY_INHERITED", "overridden_val"},
            {"GHOSTTY_PTY_REMOVED", nil}
          ]
        )

      data = wait_until_output("END_ENV")
      assert data =~ "ADDED=added_val"
      assert data =~ "INHERITED=overridden_val"
      assert data =~ "REMOVED=unset"
      assert_close(pty)
    end

    test "rejects invalid env entries" do
      Process.flag(:trap_exit, true)
      {cmd, args} = idle_command()

      assert {:error, {:pty_open_failed, message}} =
               Ghostty.PTY.start_link(cmd: cmd, args: args, env: [{"BAD", 123}])

      assert message =~ "expected env entries"
    end

    test "passes argv entries without shell joining" do
      {cmd, args, expected} = argv_probe_command()
      {:ok, pty} = Ghostty.PTY.start_link(cmd: cmd, args: args)

      data = wait_until_output(expected)
      assert data =~ expected
      assert_close(pty)
    end

    test "resize does not crash" do
      {cmd, args} = idle_command()
      {:ok, pty} = Ghostty.PTY.start_link(cmd: cmd, args: args)
      assert :ok = Ghostty.PTY.resize(pty, 120, 40)
      assert_close(pty)
    end

    test "accepts configurable reader start timeout" do
      {cmd, args} = idle_command()
      {:ok, pty} = Ghostty.PTY.start_link(cmd: cmd, args: args, reader_start_timeout: @pty_event_timeout_ms)
      assert_close(pty)
    end

    test "rejects invalid reader start timeout" do
      Process.flag(:trap_exit, true)
      {cmd, args} = idle_command()

      assert {:error, {:pty_open_failed, message}} =
               Ghostty.PTY.start_link(cmd: cmd, args: args, reader_start_timeout: -1)

      assert message =~ "reader_start_timeout"
    end
  end

  # A command that prints `text` and exits (lingering briefly on Unix so
  # close races the running child).
  defp print_command(text) do
    if @windows? do
      {"cmd.exe", ["/c", "echo", text]}
    else
      {"/bin/sh", ["-c", "printf #{text}; sleep 0.2"]}
    end
  end

  # A command that echoes its stdin back and stays alive until EOF.
  defp echo_command do
    if @windows? do
      {"findstr.exe", [".*"]}
    else
      {"/bin/cat", []}
    end
  end

  # A command that stays alive waiting for input.
  defp idle_command do
    if @windows?, do: {"cmd.exe", []}, else: {"/bin/cat", []}
  end

  defp pwd_command do
    if @windows? do
      {"cmd.exe", ["/c", "cd"]}
    else
      {"/bin/sh", ["-c", "pwd; sleep 0.2"]}
    end
  end

  defp env_probe_command do
    if @windows? do
      {"cmd.exe",
       [
         "/v:on",
         "/c",
         "if defined GHOSTTY_PTY_REMOVED (set R=!GHOSTTY_PTY_REMOVED!) else (set R=unset) & echo ADDED=!GHOSTTY_PTY_ADDED! INHERITED=!GHOSTTY_PTY_INHERITED! REMOVED=!R! END_ENV"
       ]}
    else
      {"/bin/sh",
       [
         "-c",
         ~s(printf "ADDED=%s INHERITED=%s REMOVED=%s END_ENV\\n" "$GHOSTTY_PTY_ADDED" "$GHOSTTY_PTY_INHERITED" "${GHOSTTY_PTY_REMOVED:-unset}"; sleep 0.2)
       ]}
    end
  end

  # A command that echoes its argv so quoting mistakes change the output.
  # On Windows cmd's echo prints the quoted argument verbatim, so a
  # correctly quoted single argument keeps its surrounding quotes.
  defp argv_probe_command do
    if @windows? do
      {"cmd.exe", ["/c", "echo", "hello world"], ~s("hello world")}
    else
      {"/usr/bin/python3",
       [
         "-c",
         "import sys, time; print(repr(sys.argv)); sys.stdout.flush(); time.sleep(0.2)",
         "hello world"
       ], "['-c', 'hello world']"}
    end
  end

  defp assert_close(pty) do
    ref = Process.monitor(pty)
    assert :ok = Ghostty.PTY.close(pty)
    assert_receive {:DOWN, ^ref, :process, ^pty, _reason}, @pty_event_timeout_ms
  end

  defp wait_until_output(expected) do
    deadline = System.monotonic_time(:millisecond) + @pty_event_timeout_ms
    collect_until_output(expected, "", deadline)
  end

  defp collect_until_output(expected, output, deadline) do
    if output =~ expected do
      output
    else
      receive do
        {:data, data} ->
          collect_until_output(expected, output <> data, deadline)

        {:exit, status} ->
          flunk("PTY exited with status #{inspect(status)} before output #{inspect(expected)}. Output:\n#{output}")
      after
        @poll_interval_ms ->
          if System.monotonic_time(:millisecond) < deadline do
            collect_until_output(expected, output, deadline)
          else
            flunk("Timed out waiting for output #{inspect(expected)}. Output:\n#{output}")
          end
      end
    end
  end
end
