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
  use Bitwise

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
    opts = maybe_attach_calibration(opts)


    state =
      %{cap: nil, reader_pid: nil, opts: opts, calibration: Keyword.get(opts, :calibration)}
      |> maybe_open_camera()
      |> ensure_reader()

    {:ok, state}
  end

  @impl true
  def handle_info({:camera_frame_read, %Evision.Mat{} = mat}, state) do
    broadcast_camera_frame(mat, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:camera_reader_error, reason}, state) do
    Logger.warning("CameraProducer reader error: #{inspect(reason)}; attempting reopen")
    state = state |> stop_reader() |> release_and_nil_cap() |> maybe_open_camera() |> ensure_reader()
    {:noreply, state}
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
  def terminate(_reason, state) do
    _ = stop_reader(state)
    release_camera(state.cap)
    :ok
  end

  # Internal helpers

  defp open_camera(opts) do
    index = Keyword.fetch!(opts, :device_index)
    width = Keyword.fetch!(opts, :width)
    height = Keyword.fetch!(opts, :height)
    fps = Keyword.fetch!(opts, :fps)

    case ensure_videocap(index) do
      {:ok, cap} ->
        fourcc = Evision.VideoWriter.fourcc(?M, ?J, ?P, ?G)

        _ = set_prop(cap, VCP.cv_CAP_PROP_FOURCC(), fourcc, "FOURCC")
        _ = set_prop(cap, VCP.cv_CAP_PROP_FRAME_WIDTH(), width, "WIDTH")
        _ = set_prop(cap, VCP.cv_CAP_PROP_FRAME_HEIGHT(), height, "HEIGHT")
        _ = set_prop(cap, VCP.cv_CAP_PROP_FPS(), fps, "FPS")

        log_camera_properties(index, cap)
        {:ok, cap}

      {:error, _} = err -> err
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

  defp maybe_open_camera(%{cap: %VC{}} = state), do: state

  defp maybe_open_camera(%{opts: opts} = state) do
    case open_camera(opts) do
      {:ok, cap} -> %{state | cap: cap}
      {:error, reason} ->
        Logger.error("CameraProducer: failed to open camera: #{inspect(reason)}")
        %{state | cap: nil}
    end
  end

  # Reader management
  defp ensure_reader(%{cap: %VC{} = cap, reader_pid: pid} = state) do
    cond do
      is_pid(pid) and Process.alive?(pid) -> state
      true ->
        reader = start_reader(self(), cap)
        %{state | reader_pid: reader}
    end
  end
  defp ensure_reader(state), do: state

  defp start_reader(server, cap) do
    spawn_link(fn -> reader_loop(server, cap) end)
  end

  defp stop_reader(%{reader_pid: pid} = state) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    %{state | reader_pid: nil}
  end
  defp stop_reader(state), do: state

  defp reader_loop(server, cap) do
    case VC.read(cap) do
      %Evision.Mat{} = mat ->
        send(server, {:camera_frame_read, mat})
        reader_loop(server, cap)
      false ->
        send(server, {:camera_reader_error, :eof})
        Process.sleep(50)
        reader_loop(server, cap)
      {:error, reason} ->
        send(server, {:camera_reader_error, reason})
        Process.sleep(200)
        reader_loop(server, cap)
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

  defp release_and_nil_cap(%{cap: cap} = state) do
    release_camera(cap)
    %{state | cap: nil}
  end

  defp set_prop(cap, prop, value, name) do
    case VC.set(cap, prop, value) do
      true -> true
      false ->
        Logger.warning("CameraProducer: failed to set #{name} to #{inspect(value)}")
        false
    end
  end

  defp log_camera_properties(index, cap) do
    actual_w = VC.get(cap, VCP.cv_CAP_PROP_FRAME_WIDTH())
    actual_h = VC.get(cap, VCP.cv_CAP_PROP_FRAME_HEIGHT())
    actual_fps = VC.get(cap, VCP.cv_CAP_PROP_FPS())
    code = VC.get(cap, VCP.cv_CAP_PROP_FOURCC())
    fourcc = fourcc_to_string(code)

    Logger.info(
      "CameraProducer: opened index=#{index} #{trunc(actual_w)}x#{trunc(actual_h)} @ #{Float.round(actual_fps * 1.0, 2)} fps, fourcc=#{fourcc} (#{trunc(code)})"
    )
  end

  defp fourcc_to_string(code) when is_number(code) do
    c = trunc(code)
    << (c &&& 0xFF)::8, ((c >>> 8) &&& 0xFF)::8, ((c >>> 16) &&& 0xFF)::8, ((c >>> 24) &&& 0xFF)::8 >>
  end
  defp fourcc_to_string(_), do: "????"

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
