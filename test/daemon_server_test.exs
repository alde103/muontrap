defmodule DaemonServerTest do
  use MuonTrapTest.Case
  import ExUnit.CaptureLog

  alias MuonTrap.Daemon

  describe "Behaviour" do
    defmodule MyDaemon do
      use MuonTrap.Daemon.Server, restart: :transient

      def start_link(user_init_state) do
        Daemon.Server.start_link(__MODULE__, user_init_state)
      end

      def start(user_init_state) do
        Daemon.Server.start(__MODULE__, user_init_state)
      end

      def stop(pid) do
        Daemon.Server.stop(pid)
      end

      @impl MuonTrap.Daemon.Server
      def init(%{parent_pid: p_pid} = user_init_state) do
        # initialize your process state. Your state must include ´daemon_args´,
        # which must correspond to the arguments of ´MuonTrap.Daemon.start_link´.
        send(p_pid, {self(), :init, user_init_state})
        {:ok, user_init_state}
      end

      @impl MuonTrap.Daemon.Server
      def handle_daemon(message, daemon_pid, %{parent_pid: p_pid} = state) do
        # Do something with the daemon message.
        send(p_pid, {self(), :handle_daemon, daemon_pid, message})
        {:ok, state}
      end

      @impl MuonTrap.Daemon.Server
      def handle_failure(exit_status, %{parent_pid: p_pid} = state) do
        # Do something with unexpected daemon failures.
        send(p_pid, {self(), :handle_failure, exit_status})
        {:ok, state}
      end

      @impl MuonTrap.Daemon.Server
      def handle_exit(%{parent_pid: p_pid} = state) do
        # Do something with expected daemon exit.
        send(p_pid, {self(), :handle_exit})
        {:ok, state}
      end

      @impl MuonTrap.Daemon.Server
      def terminate(:normal, %{parent_pid: p_pid} = _state) do
        send(p_pid, {self(), :terminated})
        :ok
      end

      def terminate(_reason, %{parent_pid: p_pid} = _state) do
        send(p_pid, {self(), :badexit})
        :ok
      end
    end

    test "Server does not start if it does not have the `daemon_args` key." do
      logs =
        capture_log(fn ->
          state_with_no_daemon_args = %{parent_pid: self()}
          :ignore = MyDaemon.start_link(state_with_no_daemon_args)
          Process.sleep(100)
          Logger.flush()
        end)

      assert logs =~
               "There are no arguments for the daemon, please add the `daemon_args` key in your state"
    end

    test "Full cycle (handle_daemon & handle_exit invocation)" do
      my_pid = self()
      user_initial_state = %{parent_pid: my_pid, daemon_args: ["echo", ["hello from MyDaemon"]]}
      {:ok, s_pid} = MyDaemon.start_link(user_initial_state)

      assert_receive {^s_pid, :init,
                      %{daemon_args: ["echo", ["hello from MyDaemon"]], parent_pid: ^my_pid}}

      assert_receive {^s_pid, :handle_daemon, _daemon_pid, "hello from MyDaemon"}
      assert_receive {^s_pid, :handle_exit}
      refute_receive {^s_pid, :handle_failure, _exit_status}

      :ok = MyDaemon.stop(s_pid)
      refute_receive {^s_pid, :badexit}
    end

    test "handle_failure invocation" do
      tempfile = Path.join("test", "tmp-transient_daemon")
      _ = File.rm(tempfile)
      test_path = test_path("succeed_second_time.test")

      my_pid = self()

      user_initial_state = %{
        parent_pid: my_pid,
        daemon_args: [test_path, [tempfile], [log_output: :error]]
      }

      {:ok, s_pid} = MyDaemon.start(user_initial_state)

      assert_receive {^s_pid, :init,
                      %{
                        daemon_args: [^test_path, [^tempfile], [log_output: :error]],
                        parent_pid: ^my_pid
                      }}

      refute_receive {^s_pid, :handle_exit}
      assert_receive {^s_pid, :handle_failure, 1}
      assert Process.alive?(s_pid) == false
      _ = File.rm(tempfile)
    end

    defmodule DefaultCallbacksDaemon do
      use MuonTrap.Daemon.Server

      def start(user_init_state) do
        Daemon.Server.start(__MODULE__, user_init_state)
      end
    end

    test "Default callbacks (added by __using__ macro)" do
      tempfile = Path.join("test", "tmp-transient_daemon")
      _ = File.rm(tempfile)
      test_path = test_path("succeed_second_time.test")

      my_pid = self()

      user_initial_state = %{
        parent_pid: my_pid,
        daemon_args: [test_path, [tempfile], [log_output: :error]]
      }

      bad_initial_state = %{
        parent_pid: my_pid
      }

      logs =
        capture_log(fn ->
          {:ok, _pid} = DefaultCallbacksDaemon.start(user_initial_state)
          Process.sleep(100)
          Logger.flush()
        end)

      _ = File.rm(tempfile)

      assert logs =~
               "No handle_daemon/3 clause in Elixir.DaemonServerTest.DefaultCallbacksDaemon provided for {\"Called 0 times\""

      assert logs =~
               "No handle_failure/2 clause in Elixir.DaemonServerTest.DefaultCallbacksDaemon provided for 1"

      logs =
        capture_log(fn ->
          # Bad state process should be ignored but logged.
          :ignore = DefaultCallbacksDaemon.start(bad_initial_state)
          Process.sleep(100)
          Logger.flush()
        end)

      _ = File.rm(tempfile)

      assert logs =~
               "There are no arguments for the daemon, please add the `daemon_args` key in your state"
    end

    defmodule StoppingDaemon do
      use MuonTrap.Daemon.Server

      def start_link(user_init_state) do
        Daemon.Server.start_link(__MODULE__, user_init_state)
      end

      @impl MuonTrap.Daemon.Server
      def handle_daemon(message, daemon_pid, %{parent_pid: p_pid} = state) do
        # Do something with the daemon message.
        send(p_pid, {self(), :handle_daemon, daemon_pid, message})
        # This output should end the process
        {:stop, :normal, state}
      end
    end

    test "Callbacks can end the process by using the stop tuple" do
      my_pid = self()

      user_initial_state = %{
        parent_pid: my_pid,
        daemon_args: ["echo", ["hello from StoppingDaemon"]]
      }

      {:ok, s_pid} = StoppingDaemon.start_link(user_initial_state)

      refute_receive {^s_pid, :init,
                      %{daemon_args: ["echo", ["hello from StoppingDaemon"]], parent_pid: ^my_pid}}

      assert_receive {^s_pid, :handle_daemon, _daemon_pid, "hello from StoppingDaemon"}
      refute_receive {^s_pid, :handle_exit}
      refute_receive {^s_pid, :handle_failure, _exit_status}

      assert Process.alive?(s_pid) == false
    end

    defmodule NeverStartedDaemon do
      use MuonTrap.Daemon.Server

      def start_link(user_init_state) do
        Daemon.Server.start_link(__MODULE__, user_init_state)
      end

      @impl MuonTrap.Daemon.Server
      def init(%{parent_pid: p_pid} = user_init_state) do
        # initialize your process state. Your state must include ´daemon_args´,
        # which must correspond to the arguments of ´MuonTrap.Daemon.start_link´.
        send(p_pid, {self(), :init, user_init_state})
        {:stop, :normal}
      end
    end

    test "init callback can end the process by using the Stop tuple" do
      my_pid = self()

      user_initial_state = %{
        parent_pid: my_pid,
        daemon_args: ["echo", ["hello from NeverStartedDaemon"]]
      }

      {:error, :normal} = NeverStartedDaemon.start_link(user_initial_state)

      assert_receive {s_pid, :init,
                      %{
                        daemon_args: ["echo", ["hello from NeverStartedDaemon"]],
                        parent_pid: ^my_pid
                      }}

      refute_receive {^s_pid, :handle_daemon, _daemon_pid, "hello from NeverStartedDaemon"}
      refute_receive {^s_pid, :handle_exit}
      refute_receive {^s_pid, :handle_failure, _exit_status}

      assert Process.alive?(s_pid) == false
    end
  end
end
