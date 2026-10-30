defmodule Ghostty.PTY do
  @moduledoc """
  Pseudo-terminal for running interactive programs.

  On Unix, uses `forkpty()` to create a real PTY — programs like `vim`,
  `top`, and `htop` get a TTY with the requested dimensions.

  On Windows there is no `forkpty()`: the child's stdin/stdout/stderr are
  wired to anonymous pipes instead. Programs using stdio can exchange
  data, but the child runs without a console: console APIs and terminal
  input events are unavailable. cmd.exe neither echoes input nor prints
  an interactive prompt. Bare carriage returns written through `write/2`
  are converted to CRLF. Closing terminates the direct child only;
  descendant processes are not terminated.

  Output is sent as `{:data, binary}` messages to the calling process.
  Exit is reported as `{:exit, status}` when the child exits naturally.
  Calling `close/1` may suppress the exit message if the child is
  terminated before the reader thread observes the exit.

  ## Examples

      {:ok, pty} = Ghostty.PTY.start_link(cmd: "/bin/bash")
      Ghostty.PTY.write(pty, "echo hello\\n")
      receive do: ({:data, data} -> IO.write(data))

  ## With a terminal

      {:ok, term} = Ghostty.Terminal.start_link(cols: 80, rows: 24)
      {:ok, pty} = Ghostty.PTY.start_link(cmd: "/bin/bash", cols: 80, rows: 24)

      # In a loop: forward PTY output to terminal, encode key events back to PTY

  """

  use GenServer

  alias Ghostty.PTY.Nif

  @reader_start_timeout_ms 1_000

  @type option ::
          {:cmd, Path.t()}
          | {:args, [String.t()]}
          | {:cols, pos_integer()}
          | {:rows, pos_integer()}
          | {:cwd, Path.t()}
          | {:env, [{String.t(), String.t() | nil}]}
          | {:reader_start_timeout, timeout()}
          | {:name, GenServer.name()}

  defstruct [:ref, :owner]

  @doc """
  Starts a PTY process linked to the caller.

  Output and exit messages are sent to the calling process.

  ## Options

    * `:cmd` — command to run (default: `%COMSPEC%` or `cmd.exe` on Windows;
      `$SHELL` or `/bin/sh` on Unix)
    * `:args` — argument list (default: `[]`)
    * `:cols` — terminal width in columns (default: `80`)
    * `:rows` — terminal height in rows (default: `24`)
    * `:cwd` — working directory for the child (default: inherit the BEAM
      working directory). On Unix the child `chdir`s before `exec`; on Windows
      it is passed to `CreateProcessW`.
    * `:env` — environment overrides applied on top of the inherited
      environment: `{name, value}` sets a variable and `{name, nil}` unsets
      it (default: `[]`)
    * `:reader_start_timeout` — how long to wait for the PTY reader thread to start (default: `1_000`)
    * `:name` — GenServer name registration

  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    init_opts = Keyword.put(init_opts, :owner, self())
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc "Returns a child spec for use in supervision trees."
  def child_spec(opts) do
    id = Keyword.get(opts, :id, Keyword.get(opts, :name, __MODULE__))

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000
    }
  end

  @doc "Writes data to the PTY (child's stdin)."
  @spec write(GenServer.server(), iodata()) :: :ok
  def write(pty, data) do
    GenServer.call(pty, {:write, IO.iodata_to_binary(data)})
  end

  @doc """
  Resizes the PTY and sends SIGWINCH to the child.

  On Windows this is a no-op because anonymous pipes have no window size.
  Resize an associated `Ghostty.Terminal` separately on either platform.
  """
  @spec resize(GenServer.server(), pos_integer(), pos_integer()) :: :ok
  def resize(pty, cols, rows)
      when is_integer(cols) and cols > 0 and is_integer(rows) and rows > 0 do
    GenServer.call(pty, {:resize, cols, rows})
  end

  @doc """
  Closes the PTY and terminates the child process.

  Raises if the server does not exist.
  """
  @spec close(GenServer.server()) :: :ok
  def close(pty) do
    GenServer.stop(pty)
  end

  @impl true
  def init(opts) do
    cmd = Keyword.get(opts, :cmd, default_cmd())
    args = Keyword.get(opts, :args, [])
    cols = Keyword.get(opts, :cols, 80)
    rows = Keyword.get(opts, :rows, 24)
    cwd = Keyword.get(opts, :cwd, "")
    env = Keyword.get(opts, :env, [])
    owner = Keyword.fetch!(opts, :owner)
    reader_start_timeout = Keyword.get(opts, :reader_start_timeout, @reader_start_timeout_ms)

    validate_size!(cols, rows)
    validate_timeout!(reader_start_timeout, :reader_start_timeout)
    validate_env!(env)

    ref = Nif.nif_pty_open(cmd, args, cols, rows, cwd, env, self())
    wait_until_reader_ready(reader_start_timeout)
    {:ok, %__MODULE__{ref: ref, owner: owner}}
  rescue
    e in [ErlangError, ArgumentError] ->
      {:stop, {:pty_open_failed, Exception.message(e)}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.ref, do: Nif.nif_pty_close(state.ref)
  end

  @impl true
  def handle_call({:write, data}, _from, state) do
    Nif.nif_pty_write(state.ref, data)
    {:reply, :ok, state}
  end

  def handle_call({:resize, cols, rows}, _from, state) do
    Nif.nif_pty_resize(state.ref, cols, rows)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:pty_data, data}, state) do
    send(state.owner, {:data, data})
    {:noreply, state}
  end

  def handle_info({:pty_exit, status}, state) do
    send(state.owner, {:exit, status})
    {:noreply, state}
  end

  defp wait_until_reader_ready(timeout) do
    receive do
      {:pty_ready} -> :ok
    after
      timeout -> raise "PTY reader did not start"
    end
  end

  defp default_cmd do
    case :os.type() do
      {:win32, _} -> System.get_env("COMSPEC") || "cmd.exe"
      _ -> System.get_env("SHELL") || "/bin/sh"
    end
  end

  defp validate_size!(cols, rows)
       when is_integer(cols) and cols > 0 and is_integer(rows) and rows > 0,
       do: :ok

  defp validate_size!(cols, rows) do
    raise ArgumentError,
          "expected cols and rows to be positive integers, got: cols=#{inspect(cols)}, rows=#{inspect(rows)}"
  end

  defp validate_timeout!(:infinity, _name), do: :ok

  defp validate_timeout!(timeout, _name) when is_integer(timeout) and timeout >= 0, do: :ok

  defp validate_timeout!(timeout, name) do
    raise ArgumentError, "expected #{name} to be a non-negative integer or :infinity, got: #{inspect(timeout)}"
  end

  defp validate_env!(env) when is_list(env) do
    Enum.each(env, fn
      {key, value} when is_binary(key) and (is_binary(value) or is_nil(value)) -> :ok
      other -> raise ArgumentError, "expected env entries to be {name, value | nil} binaries, got: #{inspect(other)}"
    end)
  end

  defp validate_env!(env) do
    raise ArgumentError, "expected :env to be a list of {name, value | nil} entries, got: #{inspect(env)}"
  end
end
