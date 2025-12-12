defmodule SendSlam.ImageTimer do
  @moduledoc """
  GenServer that listens for `{:camera_frame, event}` messages broadcast via
  `SendSlam.CameraRegistry`, serializes them to MessagePack, and forwards them to
  every backend registered in `SendSlam.BackendRegistry`.
  """

  use GenServer
  require Logger
  alias Evision, as: Cv
  alias Msgpax
  alias Nx
  alias SendSlam.CalibrationCache

  @registry SendSlam.BackendRegistry

  @camera_registry SendSlam.CameraRegistry

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    _ = Registry.register(@camera_registry, :clients, %{})
    {:ok, %{last_calibration_digest: nil, fps_count: 0, fps_last_log_ts: monotonic_seconds()}}
  end

  @impl true
  def handle_info({:camera_frame, event}, state) do
    state = process_event(event, state)

    # FPS accounting: increment count and log once per second
    now = monotonic_seconds()
    fps_count = state.fps_count + 1
    state = %{state | fps_count: fps_count}

    if now - state.fps_last_log_ts >= 1.0 do
      Logger.info("ImageConsumer incoming FPS: #{fps_count}")
      {:noreply, %{state | fps_count: 0, fps_last_log_ts: now}}
    else
      {:noreply, state}
    end
  end

  def handle_info(other, state) do
    Logger.debug("ImageConsumer ignoring message: #{inspect(other)}")
    {:noreply, state}
  end

  defp process_event({:error, reason}, state) do
    Logger.warning("Frame error: #{inspect(reason)}")
    state
  end

  defp process_event(other, state) do
    Logger.debug("Ignoring unexpected camera event: #{inspect(other)}")
    state
  end
  defp monotonic_seconds do
    System.monotonic_time(:nanosecond) / 1_000_000_000
  end


end
