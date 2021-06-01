defmodule MuonTrap.Daemon.Server do
  use GenServer

  require Logger

  @moduledoc """
  This module implements a behaviour that wraps `MuonTrap.Daemon` for easy handling daemon messages with a GenServer state e.g:

  ```
  defmodule MyDaemon do
    use MuonTrap.Daemon.Server
    alias MuonTrap.Daemon

    def start_link(args) do
      Daemon.Server.start_link(__MODULE__, args)
    end

    @impl MuonTrap.Daemon.Server
    def handle_daemon(_message, _daemon_pid, state) do
      {:ok, state}
    end
  end
  ```
  """

  @type state_with_daemon_args ::
          %{daemon_args: list()}
          | term

  @doc """
  Callback to initialize a `MuonTrap.Daemon.Server`.
  """
  @callback init(args) ::
              {:ok, state}
              | {:stop, reason}
              | :ignore
            when args: term, reason: term, state: state_with_daemon_args

  @doc """
  Callback to handle incoming messages from a daemon.
  """
  @callback handle_daemon(msg :: term, daemon_pid :: pid, state :: state_with_daemon_args) ::
              {:ok, new_state}
              | {:stop, reason, new_state}
            when new_state: state_with_daemon_args, reason: term

  @doc """
  Callback to handle unexpected failures from a daemon.
  """
  @callback handle_failure(exit_status :: integer, state :: state_with_daemon_args) ::
              {:ok, new_state}
              | {:stop, reason, new_state}
            when new_state: state_with_daemon_args, reason: term

  @doc """
  Callback to handle expected exit from a daemon.
  """
  @callback handle_exit(state :: state_with_daemon_args) ::
              {:ok, new_state}
              | {:stop, reason, new_state}
            when new_state: state_with_daemon_args, reason: term

  @doc """
  Callback to handle `Yggdrasil` termination.
  """
  @callback terminate(reason, state) ::
              term()
            when state: term(), reason: term()

  defmodule State do
    @moduledoc false

    defstruct [
      :module,
      :user_state,
      :daemon_pid
    ]
  end

  @doc false
  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      @behaviour MuonTrap.Daemon.Server

      @doc false
      def child_spec(init_arg) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [init_arg]}
        }

        Supervisor.child_spec(default, unquote(Macro.escape(opts)))
      end

      @impl MuonTrap.Daemon.Server
      def init(%{daemon_args: _args} = user_init_args), do: {:ok, user_init_args}
      @impl MuonTrap.Daemon.Server
      def init(user_init_args) do
        require Logger

        msg = """
        There are no arguments to spawn the daemon, please add the `daemon_args` in #{
          inspect(user_init_args)
        }
        """

        Logger.warn(msg)
        :ignore
      end

      @impl MuonTrap.Daemon.Server
      def handle_daemon(daemon_output, daemon_pid, state) do
        require Logger

        Logger.warn(
          "No handle_daemon/3 clause in #{__MODULE__} provided for #{
            inspect({daemon_output, daemon_pid})
          }"
        )

        {:ok, state}
      end

      @impl MuonTrap.Daemon.Server
      def handle_exit(state) do
        {:ok, state}
      end

      @impl MuonTrap.Daemon.Server
      def handle_failure(exit_status, state) do
        require Logger

        Logger.warn(
          "No handle_failure/2 clause in #{__MODULE__} provided for #{inspect(exit_status)}"
        )

        {:ok, state}
      end

      @impl MuonTrap.Daemon.Server
      def terminate(_, _), do: :ok

      defoverridable child_spec: 1,
                     init: 1,
                     handle_daemon: 3,
                     handle_exit: 1,
                     handle_failure: 2,
                     terminate: 2
    end
  end

  @doc """
  Starts a `MuonTrap.Daemon` process linked to the current process.
  Given a `module`, `args` and some optional `options`.
  """
  @spec start_link(module(), term()) :: GenServer.on_start()
  @spec start_link(module(), term(), GenServer.options()) ::
          GenServer.on_start()
  def start_link(module, args, options \\ []) do
    GenServer.start_link(__MODULE__, [module, args], options)
  end

  @doc """
  Stops the `MuonTrap.Daemon` given optional `reason` and `timeout`.
  """
  @spec stop(GenServer.server()) :: :ok
  @spec stop(GenServer.server(), term()) :: :ok
  @spec stop(GenServer.server(), term(), :infinity | non_neg_integer()) :: :ok
  defdelegate stop(server, reason \\ :normal, timeout \\ :infinity),
    to: GenServer

  # GenServer callbacks

  @impl GenServer
  def init([module, args]) do
    case module.init(args) do
      {:ok, user_state} ->
        with state <- %State{module: module, user_state: user_state},
             daemon_args <- Map.get(user_state, :daemon_args, nil),
             false <- is_nil(daemon_args) do
          {:ok, state, {:continue, {:start_daemon, daemon_args}}}
        else
          _error ->
            msg = """
            There are no arguments to spawn the daemon, please add the `daemon_args` in #{
              inspect(user_state)
            }
            """

            Logger.warn(msg)
            :ignore
        end

      {:stop, _} = stop ->
        stop

      :ignore ->
        :ignore
    end
  end

  @impl GenServer
  def handle_continue({:start_daemon, [cmd_bin, cmd_args]}, %State{} = state) do
    {:ok, d_pid} = MuonTrap.Daemon.start_link(cmd_bin, cmd_args, controlling_process: self())
    {:noreply, %{state | daemon_pid: d_pid}}
  end

  def handle_continue({:start_daemon, daemon_args}, %State{} = state) do
    {:ok, d_pid} =
      apply(MuonTrap.Daemon, :start_link, daemon_args ++ [controlling_process: self()])

    {:noreply, %{state | daemon_pid: d_pid}}
  end

  @impl GenServer
  def handle_info({:daemon_output, message}, %State{module: module, daemon_pid: d_pid} = state) do
    run(&module.handle_daemon(message, d_pid, &1), state)
  end

  def handle_info({:daemon_exit, :normal, _exit_status}, %State{module: module} = state) do
    run(&module.handle_exit(&1), state)
  end

  def handle_info({:daemon_exit, _reason, exit_status}, %State{module: module} = state) do
    run(&module.handle_failure(exit_status, &1), state)
  end

  @impl GenServer
  def terminate(reason, %State{module: module, user_state: user_state}) do
    module.terminate(reason, user_state)
  end

  # Runs callbacks
  @spec run((term -> {:ok, term()} | {:stop, term(), term()}), State.t()) ::
          {:noreply, State.t()} | {:stop, term(), State.t()}
  defp run(callback, %State{user_state: user_state} = state) do
    case callback.(user_state) do
      {:ok, user_state} ->
        {:noreply, %State{state | user_state: user_state}}

      {:stop, reason, user_state} ->
        {:stop, reason, %State{state | user_state: user_state}}
    end
  end
end
