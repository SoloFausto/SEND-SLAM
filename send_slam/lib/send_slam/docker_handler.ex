defmodule SendSlam.DockerHandler do
  @moduledoc """
  GenServer for managing and monitoring a Docker container running the `orbslam3` image.

  Responsibilities:
  - Start the container with forwarded environment variables.
  - Periodically monitor container health/state.
  - Provide APIs to fetch status, stop container, and stream/tail logs.

  Environment variables can be provided in three ways (merged in this order, later overrides earlier):
  1. Application config: `config :send_slam, :orbslam3_env, %{ "FOO" => "BAR" }`
  2. OS environment prefixed with `ORBSLAM3_` (e.g. `ORBSLAM3_MAP_PATH=/data/maps`). Prefix is stripped.
  3. Runtime option `env: %{ "FOO" => "BAZ" }` passed to `start_link/1`.

  Contract:
  - start_link(opts) -> {:ok, pid}
  	opts: [image: "orbslam3", name: "orbslam3", pull: true, monitor_interval: 5_000, env: %{}, docker_bin: "docker"]
  - start_container(pid) -> {:ok, container_id} | {:error, reason}
  - stop_container(pid) -> :ok | {:error, reason}
  - status(pid) -> %{state: atom(), container_id: String.t() | nil, last_seen: integer() | nil}
  - logs(pid, lines \\ 100) -> {:ok, String.t()} | {:error, reason}

  Monitoring:
  The process schedules `:poll` messages; on each poll it runs `docker inspect -f '{{.State.Running}}' <name>`.
  If container dies, it sets state to :exited. Auto-restart can be enabled with `auto_restart: true` option.
  """

  use GenServer
  require Logger

  @type docker_state :: :initial | :running | :exited | :error
  @default_image "orbslam3"
  @default_name "orbslam3"
  @default_interval 5_000

  # Public API
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :server_name, __MODULE__))

  def start_container(pid), do: GenServer.call(pid, :start_container, 30_000)
  def stop_container(pid), do: GenServer.call(pid, :stop_container, 15_000)
  def status(pid), do: GenServer.call(pid, :status, 5_000)
  def logs(pid, lines \\ 100), do: GenServer.call(pid, {:logs, lines}, 15_000)

  # State struct
  defstruct [
    :image,
    :name,
    :container_id,
    :monitor_interval,
    :docker_bin,
    :last_seen,
    :env_map,
    state: :initial
  ]

  @impl true
  def init(opts) do
    image = Keyword.get(opts, :image, @default_image)
    name = Keyword.get(opts, :name, @default_name)
    monitor_interval = Keyword.get(opts, :monitor_interval, @default_interval)
    docker_bin = Keyword.get(opts, :docker_bin, "docker")
    runtime_env = Keyword.get(opts, :env, %{}) |> normalize_env_map()

    merged_env =
      application_env_map()
      |> Map.merge(os_prefixed_env())
      |> Map.merge(runtime_env)

    state = %__MODULE__{
      image: image,
      name: name,
      monitor_interval: monitor_interval,
      docker_bin: docker_bin,
      env_map: merged_env
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:start_container, _from, %{container_id: cid} = state) when is_binary(cid) do
    {:reply, {:ok, cid}, state}
  end

  def handle_call(:start_container, _from, state) do
    case run_container(state) do
      {:ok, container_id} ->
        new_state = %{state | container_id: container_id, state: :running, last_seen: now_ms()}
        schedule_poll(new_state)
        {:reply, {:ok, container_id}, new_state}

      {:error, reason} ->
        # Fail fast so supervisor can restart us
        {:stop, {:container_start_failed, reason}, {:error, reason}, %{state | state: :error}}
    end
  end

  def handle_call(:stop_container, _from, state) do
    case stop_container_cmd(state) do
      :ok -> {:reply, :ok, %{state | state: :exited}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state) do
    resp = %{state: state.state, container_id: state.container_id, last_seen: state.last_seen}
    {:reply, resp, state}
  end

  def handle_call({:logs, lines}, _from, state) do
    case fetch_logs(state, lines) do
      {:ok, logs} -> {:reply, {:ok, logs}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    case poll_container(state) do
      {:ok, running_state} ->
        schedule_poll(running_state)
        {:noreply, running_state}

      {:error, reason, error_state} ->
        # Terminate so supervisor can restart (desired behavior)
        {:stop, reason, error_state}
    end
  end

  defp poll_container(%{container_id: nil} = state), do: {:error, :no_container, state}

  defp poll_container(state) do
    case docker_cmd(state.docker_bin, ["inspect", "-f", "{{.State.Running}}", state.name]) do
      {:ok, "true" <> _} ->
        {:ok, %{state | state: :running, last_seen: now_ms()}}

      {:ok, "false" <> _} ->
        Logger.error("Container #{state.name} not running; terminating for supervised restart")
        {:error, :container_not_running, %{state | state: :exited}}

      {:error, reason} ->
        Logger.error("Docker inspect failed (#{inspect(reason)}); terminating handler")
        {:error, {:inspect_failed, reason}, %{state | state: :error}}
    end
  end

  defp schedule_poll(%{monitor_interval: interval}) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :poll, interval)
  end

  defp schedule_poll(_), do: :ok

  # Run container
  defp run_container(state) do
    # Build env args
    env_args = Enum.flat_map(state.env_map, fn {k, v} -> ["-e", "#{k}=#{v}"] end)
    args = ["run", "-d", "--name", state.name] ++ env_args ++ [state.image]

    case docker_cmd(state.docker_bin, args) do
      {:ok, id} -> {:ok, String.trim(id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop_container_cmd(state) do
    case docker_cmd(state.docker_bin, ["rm", "-f", state.name]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_logs(state, lines) do
    case docker_cmd(state.docker_bin, ["logs", "--tail", Integer.to_string(lines), state.name]) do
      {:ok, logs} -> {:ok, logs}
      {:error, reason} -> {:error, reason}
    end
  end

  # Docker command helper
  defp docker_cmd(bin, args) do
    case System.cmd(bin, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {code, output}}
    end
  rescue
    e -> {:error, e}
  end

  # Environment merging helpers
  defp application_env_map do
    Application.get_env(:send_slam, :orbslam3_env, %{}) |> normalize_env_map()
  end

  defp os_prefixed_env do
    System.get_env()
    |> Enum.filter(fn {k, _v} -> String.starts_with?(k, "ORBSLAM3_") end)
    |> Enum.map(fn {k, v} -> {String.replace_prefix(k, "ORBSLAM3_", ""), v} end)
    |> Enum.into(%{})
    |> normalize_env_map()
  end

  defp normalize_env_map(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
    |> Enum.into(%{})
  end

  defp normalize_env_map(_), do: %{}

  defp now_ms, do: System.monotonic_time(:millisecond)
end
