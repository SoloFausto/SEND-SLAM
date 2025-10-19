defmodule SendSlam.CameraProducer do
  @moduledoc """
  Simple GenStage producer that reads frames from a camera using Evision (OpenCV)
  and emits them one by one on demand, paced by a timer.

  Options:
  - device_index: camera index to open (default: 0)
  - width: desired frame width (default: 640)
  - height: desired frame height (default: 480)
  - fps: target frames per second (default: 30)
  - name: registered name for the producer (default: module name)

  Each event is either {:ok, %Evision.Mat{}} or {:error, reason}.
  """

  use GenStage
  require Logger

  alias Evision.VideoCapture, as: VC
  alias Evision.VideoCaptureProperties, as: VCP

  @type opts :: [
          {:device_index, pos_integer()}
          | {:width, pos_integer()}
          | {:height, pos_integer()}
          | {:fps, pos_integer()}
          | {:name, atom() | {:via, module(), term()} | {:global, term()}}
        ]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenStage.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    fps = Keyword.fetch!(opts, :fps)
    interval_ms = max(1, div(1000, max(1, fps)))

    state = %{
      cap: nil,
      pending_demand: 0,
      opts: opts,
      interval_ms: interval_ms
    }

    # Try to open camera now
    state =
      case open_camera(opts) do
        {:ok, cap} ->
          %{state | cap: cap}

        {:error, reason} ->
          Logger.error("CameraProducer: failed to open camera: #{inspect(reason)}")
          state
      end

    # Kick off the timer-driven loop
    schedule_tick(interval_ms)
    {:producer, state}
  end

  @impl true
  def handle_demand(incoming, state) when incoming > 0 do
    {:noreply, [], %{state | pending_demand: state.pending_demand + incoming}}
  end

  @impl true
  def handle_info(:tick, state) do
    # Ensure periodic pacing
    schedule_tick(state.interval_ms)

    cond do
      state.pending_demand <= 0 ->
        {:noreply, [], state}

      is_nil(state.cap) ->
        # Try to open camera lazily
        case open_camera(state.opts) do
          {:ok, cap} ->
            {:noreply, [], %{state | cap: cap}}

          {:error, reason} ->
            Logger.error("CameraProducer: open failed on tick: #{inspect(reason)}")
            {:noreply, [], state}
        end

      true ->
        case VC.read(state.cap) do
          %Evision.Mat{} = mat ->
            {:noreply, [{:ok, mat}], %{state | pending_demand: state.pending_demand - 1}}

          false ->
            {:noreply, [{:error, :eof_or_disconnected}],
             %{state | pending_demand: state.pending_demand - 1}}

          {:error, reason} ->
            {:noreply, [{:error, reason}], %{state | pending_demand: state.pending_demand - 1}}
        end
    end
  end

  @impl true
  def terminate(_reason, %{cap: cap} = _state) do
    if cap, do: VC.release(cap)
    :ok
  end

  # Internal helpers

  defp open_camera(opts) do
    index = Keyword.fetch!(opts, :device_index)
    width = Keyword.fetch!(opts, :width)
    height = Keyword.fetch!(opts, :height)
    fps = Keyword.fetch!(opts, :fps)

    with {:ok, cap} <- ensure_videocap(index),
         true <- VC.set(cap, VCP.cv_CAP_PROP_FRAME_WIDTH(), width) || true,
         true <- VC.set(cap, VCP.cv_CAP_PROP_FRAME_HEIGHT(), height) || true,
         true <- VC.set(cap, VCP.cv_CAP_PROP_FPS(), fps) || true do
      {:ok, cap}
    else
      {:error, _} = err -> err
      false -> {:error, :set_property_failed}
    end
  end

  defp ensure_videocap(index) do
    case VC.videoCapture(index) do
      %VC{} = cap ->
        case VC.isOpened(cap) do
          true ->
            {:ok, cap}

          _ ->
            case VC.open(cap, index) do
              true -> {:ok, cap}
              _ -> {:error, :open_failed}
            end
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_videocap, other}}
    end
  end

  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)
end
