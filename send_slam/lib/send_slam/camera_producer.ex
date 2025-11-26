defmodule SendSlam.CameraProducer do
  @moduledoc """
  GenServer that captures frames from a camera using Evision (OpenCV) and
  broadcasts them to all processes registered under `SendSlam.CameraRegistry`.

  Options:
  - device_index: camera index to open (default: 0)
  - width: desired frame width (default: 640)
  - height: desired frame height (default: 480)
  - fps: target frames per second (default: 30)
  - name: registered name for the producer (default: module name)

  Frames are sent to interested consumers via `Registry.dispatch/3` and tagged as
  `{:camera_frame, event}` tuples.
  """

  use GenServer
  require Logger

  alias Evision.VideoCapture, as: VC
  alias Evision.VideoCaptureProperties, as: VCP
  alias SendSlam.CameraCalibrator

  @calibration_registry SendSlam.CalibrationRegistry
  @camera_registry SendSlam.CameraRegistry

  @type calibration_result :: %{
          camera_matrix: Evision.Mat.t(),
          distortion_coeffs: Evision.Mat.t(),
          reprojection_error: float(),
          successful_frames: non_neg_integer()
        }

  @type opts :: [
          {:device_index, pos_integer()}
          | {:width, pos_integer()}
          | {:height, pos_integer()}
          | {:fps, pos_integer()}
          | {:name, atom() | {:via, module(), term()} | {:global, term()}}
      | {:calibration, calibration_result() | nil}
      | {:calibration_file, Path.t() | nil}
      | {:buffer_size, pos_integer()}
        ]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    _ = Registry.register(@calibration_registry, :clients, %{})

    fps = Keyword.get(opts, :fps, 30)
    interval_ms = max(1, div(1000, max(1, fps)))
    opts = maybe_attach_calibration(opts)


    state =
      %{cap: nil, opts: opts, interval_ms: interval_ms, calibration: Keyword.get(opts, :calibration)}
      |> maybe_open_camera()

    {:ok, schedule_tick(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    state =
      state
      |> maybe_open_camera()
      |> capture_and_broadcast()

    {:noreply, schedule_tick(state)}
  end

  def handle_info({:broadcast_message, {:calibration, calib_data}}, state) do
    opts = Keyword.put(state.opts, :calibration, calib_data)
    maybe_persist_calibration(calib_data, opts)
    {:noreply, %{state | opts: opts, calibration: calib_data}}
  end

  def handle_info(other, state) do
    Logger.debug("CameraProducer ignoring message: #{inspect(other)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{cap: cap}) do
    release_camera(cap)
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

  defp schedule_tick(state) do
    Process.send_after(self(), :tick, state.interval_ms)
    state
  end

  defp maybe_open_camera(%{cap: %VC{}} = state), do: state

  defp maybe_open_camera(%{opts: opts} = state) do
    case open_camera(opts) do
      {:ok, cap} -> %{state | cap: cap}
      {:error, reason} ->
        Logger.error("CameraProducer: failed to open camera: #{inspect(reason)}")
        %{state | cap: nil}
    end
  end

  defp capture_and_broadcast(%{cap: nil} = state), do: state

  defp capture_and_broadcast(%{cap: cap} = state) do
    case VC.read(cap) do
      %Evision.Mat{} = mat ->
        broadcast_camera_frame(mat, state)
        state

      false ->
        Logger.warning("CameraProducer: camera feed ended; reopening soon")
        release_camera(cap)
        %{state | cap: nil}

      {:error, reason} ->
        Logger.error("CameraProducer: read failed #{inspect(reason)}")
        release_camera(cap)
        %{state | cap: nil}
    end
  end

  defp broadcast_camera_frame(%Evision.Mat{} = mat, state) do
    timestamp = System.monotonic_time(:microsecond) / 1_000_000

    payload =
      {:ok,
       [
         frame: mat,
         calibration: state.calibration,
         timestamp: timestamp,
         fps: Keyword.get(state.opts, :fps, 30),
         camera_id: Keyword.get(state.opts, :device_index, 0)
       ]}

    Registry.dispatch(@camera_registry, :clients, fn entries ->
      for {pid, _} <- entries do
        send(pid, {:camera_frame, payload})
      end
    end)
  end

  defp release_camera(%VC{} = cap), do: VC.release(cap)
  defp release_camera(_), do: :ok

  defp maybe_attach_calibration(opts) do
    case {Keyword.get(opts, :calibration), Keyword.get(opts, :calibration_file)} do
      {calibration, _} when not is_nil(calibration) ->
        opts

      {nil, path} when is_binary(path) and path != "" ->
        expanded = Path.expand(path)

        case CameraCalibrator.load_from_file(expanded) do
          {:ok, calibration} ->
            Logger.info("CameraProducer: loaded calibration from #{expanded}")
            broadcast_message(
              {:calibration, calibration},
              SendSlam.CalibrationRegistry
            )
            Keyword.put(opts, :calibration, calibration)
          {:error, :enoent} ->
            Logger.info(
              "CameraProducer: calibration file #{expanded} not found; continuing without it"
            )

            opts

          {:error, reason} ->
            Logger.warning(
              "CameraProducer: failed to load calibration from #{expanded}: #{inspect(reason)}"
            )

            opts
        end

      _ ->
        opts
    end
  end

  defp maybe_persist_calibration(calibration, opts) do
    case Keyword.get(opts, :calibration_file) do
      path when is_binary(path) and path != "" ->
        case CameraCalibrator.save_to_file(calibration, path) do
          {:ok, written_path} ->
            Logger.info("CameraProducer: wrote calibration to #{written_path}")

          {:error, reason} ->
            Logger.warning(
              "CameraProducer: unable to write calibration to #{path}: #{inspect(reason)}"
            )
        end

      _ ->
        :ok
    end
  end
  defp broadcast_message(message, registry) do
    from = self()

    Registry.dispatch(registry, :clients, fn entries ->
      for {pid, _} <- entries, pid != from do
        send(pid, {:broadcast_message, message})
      end
    end)

    :ok
  end

end
