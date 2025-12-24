defmodule SendSlam.VideoProducer do
  @moduledoc """
  GenServer that reads frames from a video file using Evision (OpenCV) and
  broadcasts them to all processes registered under `SendSlam.CameraRegistry`.

  Options:
  - video_path: path to the video file to open (required)
  - fps: playback frames per second (optional; if omitted, reads as fast as possible)
  - api_preference: OpenCV backend to use (optional; default tries ffmpeg/gstreamer/any)
  - loop: whether to loop back to the beginning on EOF (default: true)
  - warmup_ms: how long to keep broadcasting the first frame before continuing (default: 0)
  - name: registered name for the producer (default: module name)

  Frames are sent to interested consumers via `Registry.dispatch/3` and tagged as
  `{:camera_frame, event}` tuples.
  """

  use GenServer
  require Logger
  use Bitwise

  alias Evision.VideoCapture, as: VC
  alias Evision.VideoCaptureAPIs, as: VCA
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
          {:video_path, Path.t()}
          | {:fps, pos_integer()}
          | {:api_preference, :any | :ffmpeg | :gstreamer | :opencv_mjpeg | :images | integer()}
          | {:loop, boolean()}
      | {:warmup_ms, non_neg_integer()}
          | {:name, atom() | {:via, module(), term()} | {:global, term()}}
          | {:calibration, calibration_result() | nil}
          | {:calibration_file, Path.t() | nil}
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
      |> maybe_open_video()
      |> ensure_reader()

    {:ok, state}
  end

  @impl true
  def handle_info({:camera_frame_read, %Evision.Mat{} = mat}, state) do
    broadcast_video_frame(mat, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:camera_reader_error, reason}, state) do
    Logger.warning("VideoProducer reader error: #{inspect(reason)}; attempting reopen")
    state = state |> stop_reader() |> release_and_nil_cap() |> maybe_open_video() |> ensure_reader()
    {:noreply, state}
  end

  def handle_info({:broadcast_message, {:calibration, calib_data}}, state) do
    opts = Keyword.put(state.opts, :calibration, calib_data)
    maybe_persist_calibration(calib_data, opts)
    {:noreply, %{state | opts: opts, calibration: calib_data}}
  end

  def handle_info(other, state) do
    Logger.debug("VideoProducer ignoring message: #{inspect(other)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = stop_reader(state)
    release_camera(state.cap)
    :ok
  end

  # Internal helpers

  defp open_video(opts) do
    video_path = resolve_media_path!(Keyword.fetch!(opts, :video_path))
    api_pref = Keyword.get(opts, :api_preference)

    case ensure_videocap(video_path, api_pref) do
      {:ok, cap} ->
        log_video_properties(video_path, cap)
        {:ok, cap}

      {:error, _} = err -> err
    end
  end

  defp ensure_videocap(video_path, api_pref) when is_binary(video_path) do
    unless file_exists_or_sequence_exists?(video_path, api_pref) do
      extra_hint =
        case image_sequence_first_frames(video_path) do
          [] -> ""
          candidates -> " sequence_candidates=#{inspect(candidates)}"
        end

      Logger.error(
        "VideoProducer: video file not found: #{video_path} (cwd=#{File.cwd!()}, app_dir=#{Application.app_dir(:send_slam)})" <>
          extra_hint
      )

      {:error, :enoent}
    else
      file_stat =
        case File.stat(video_path) do
          {:ok, stat} -> stat
          {:error, _} -> nil
        end

      apis = resolve_api_preferences(api_pref)

      # First try: let OpenCV pick the backend. Some builds misbehave when forced.
      base_attempt =
        case VC.videoCapture(filename: video_path) do
          %VC{} = cap ->
            if VC.isOpened(cap), do: {:ok, cap}, else: {:error, :open_failed}

          {:ok, %VC{} = cap} ->
            if VC.isOpened(cap), do: {:ok, cap}, else: {:error, :open_failed}

          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_videocap, other}}
        end

      case base_attempt do
        {:ok, cap} ->
          {:ok, cap}

        {:error, _} ->
          Enum.reduce_while(apis, {:error, :open_failed}, fn api, _acc ->
            case VC.videoCapture(filename: video_path, apiPreference: api) do
              %VC{} = cap ->
                if VC.isOpened(cap) do
                  {:halt, {:ok, cap}}
                else
                  {:cont, {:error, :open_failed}}
                end

              {:ok, %VC{} = cap} ->
                if VC.isOpened(cap) do
                  {:halt, {:ok, cap}}
                else
                  {:cont, {:error, :open_failed}}
                end

              {:error, reason} ->
                {:cont, {:error, reason}}

              other ->
                {:cont, {:error, {:unexpected_videocap, other}}}
            end
          end)
      end
      |> case do
        {:ok, _cap} = ok ->
          ok

        {:error, reason} = err ->
          stat_hint =
            case file_stat do
              nil -> "stat=unavailable"
              stat -> "size=#{stat.size} mode=#{Integer.to_string(stat.mode, 8)}"
            end

          Logger.error(
            "VideoProducer: unable to open #{video_path} (#{stat_hint}); tried apiPreference=#{inspect(apis)}; last_error=#{inspect(reason)}. " <>
              "If your OpenCV build lacks FFmpeg/GStreamer support (common), re-encode to MJPG .avi (keeping it <~2GB helps for AVI) or convert to an image sequence."
          )

          err
      end
    end
  end

  defp file_exists_or_sequence_exists?(path, api_pref) when is_binary(path) do
    if File.exists?(path) do
      true
    else
      wants_images? = api_pref in [:images, VCA.cv_CAP_IMAGES()]

      if wants_images? or looks_like_image_sequence?(path) do
        Enum.any?(image_sequence_first_frames(path), &File.exists?/1)
      else
        false
      end
    end
  end

  defp looks_like_image_sequence?(path) when is_binary(path) do
    String.contains?(path, "%d") or Regex.match?(~r/%0?\d*d/, path)
  end

  defp image_sequence_first_frames(path) when is_binary(path) do
    if looks_like_image_sequence?(path) do
      [format_sequence_filename(path, 0), format_sequence_filename(path, 1)]
      |> Enum.uniq()
    else
      []
    end
  end

  defp format_sequence_filename(pattern, index) when is_binary(pattern) and is_integer(index) do
    case Regex.run(~r/%0?(\d*)d/, pattern, capture: :all_but_first) do
      [width_str] ->
        width =
          case width_str do
            "" -> 0
            s -> String.to_integer(s)
          end

        number =
          index
          |> Integer.to_string()
          |> maybe_pad_leading(width)

        Regex.replace(~r/%0?\d*d/, pattern, number, global: false)

      _ ->
        # Fallback for plain %d patterns
        String.replace(pattern, "%d", Integer.to_string(index), global: false)
    end
  end

  defp maybe_pad_leading(str, width) when is_binary(str) and is_integer(width) and width > 0 do
    String.pad_leading(str, width, "0")
  end

  defp maybe_pad_leading(str, _width), do: str

  defp resolve_api_preferences(nil) do
    # Prefer file-capable backends. CAP_OPENCV_MJPEG and CAP_IMAGES commonly warn
    # "can't be used to capture by name" for filenames and usually don't help here.
    [VCA.cv_CAP_FFMPEG(), VCA.cv_CAP_GSTREAMER(), VCA.cv_CAP_ANY()]
  end

  defp resolve_api_preferences(:any), do: [VCA.cv_CAP_ANY()]
  defp resolve_api_preferences(:ffmpeg), do: [VCA.cv_CAP_FFMPEG()]
  defp resolve_api_preferences(:gstreamer), do: [VCA.cv_CAP_GSTREAMER()]
  defp resolve_api_preferences(:opencv_mjpeg), do: [VCA.cv_CAP_OPENCV_MJPEG()]
  defp resolve_api_preferences(:images), do: [VCA.cv_CAP_IMAGES()]
  defp resolve_api_preferences(api) when is_integer(api), do: [api]
  defp resolve_api_preferences(_), do: resolve_api_preferences(nil)

  defp maybe_open_video(%{cap: %VC{}} = state), do: state

  defp maybe_open_video(%{opts: opts} = state) do
    case open_video(opts) do
      {:ok, cap} -> %{state | cap: cap}
      {:error, reason} ->
        Logger.error("VideoProducer: failed to open video: #{inspect(reason)}")
        %{state | cap: nil}
    end
  end

  # Reader management
  defp ensure_reader(%{cap: %VC{} = cap, reader_pid: pid} = state) do
    cond do
      is_pid(pid) and Process.alive?(pid) -> state
      true ->
        loop? = Keyword.get(state.opts, :loop, true)
        fps = Keyword.get(state.opts, :fps)
        warmup_ms = Keyword.get(state.opts, :warmup_ms, 0)
        reader = start_reader(self(), cap, loop?, fps, warmup_ms)
        %{state | reader_pid: reader}
    end
  end
  defp ensure_reader(state), do: state

  defp start_reader(server, cap, loop?, fps, warmup_ms) do
    interval_ms = fps_to_interval_ms(fps)
    spawn_link(fn -> reader_loop(server, cap, loop?, interval_ms, warmup_ms, true) end)
  end

  defp stop_reader(%{reader_pid: pid} = state) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    %{state | reader_pid: nil}
  end
  defp stop_reader(state), do: state

  defp reader_loop(server, cap, loop?, interval_ms, warmup_ms, is_first_frame?) do
    case VC.read(cap) do
      %Evision.Mat{} = mat ->
        if is_first_frame? and is_integer(warmup_ms) and warmup_ms > 0 do
          warmup_broadcast(server, mat, warmup_ms, interval_ms)
        end

        send(server, {:camera_frame_read, mat})
        maybe_sleep(interval_ms)
        reader_loop(server, cap, loop?, interval_ms, warmup_ms, false)
      false ->
        if loop? do
          _ = VC.set(cap, VCP.cv_CAP_PROP_POS_FRAMES(), 0)
          Process.sleep(10)
          reader_loop(server, cap, loop?, interval_ms, warmup_ms, true)
        else
          send(server, {:camera_reader_error, :eof})
        end
      {:error, reason} ->
        send(server, {:camera_reader_error, reason})
        Process.sleep(200)
        reader_loop(server, cap, loop?, interval_ms, warmup_ms, is_first_frame?)
    end
  end

  defp warmup_broadcast(server, %Evision.Mat{} = mat, warmup_ms, interval_ms) do
    tick_ms = if is_integer(interval_ms) and interval_ms > 0, do: interval_ms, else: 10
    start_ms = System.monotonic_time(:millisecond)
    do_warmup_broadcast(server, mat, start_ms, warmup_ms, tick_ms)
  end

  defp do_warmup_broadcast(server, mat, start_ms, warmup_ms, tick_ms) do
    elapsed = System.monotonic_time(:millisecond) - start_ms

    if elapsed < warmup_ms do
      send(server, {:camera_frame_read, mat})
      Process.sleep(tick_ms)
      do_warmup_broadcast(server, mat, start_ms, warmup_ms, tick_ms)
    else
      :ok
    end
  end

  defp broadcast_video_frame(%Evision.Mat{} = mat, state) do
    timestamp = System.monotonic_time(:microsecond) / 1_000_000

    payload =
      {:ok,
       [
         frame: mat,
         calibration: state.calibration,
         timestamp: timestamp,
         fps: Keyword.get(state.opts, :fps, 30),
         camera_id: Keyword.get(state.opts, :camera_id, 1)
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
        Logger.warning("VideoProducer: failed to set #{name} to #{inspect(value)}")
        false
    end
  end

  defp log_video_properties(video_path, cap) do
    actual_w = VC.get(cap, VCP.cv_CAP_PROP_FRAME_WIDTH())
    actual_h = VC.get(cap, VCP.cv_CAP_PROP_FRAME_HEIGHT())
    actual_fps = VC.get(cap, VCP.cv_CAP_PROP_FPS())
    frame_count = VC.get(cap, VCP.cv_CAP_PROP_FRAME_COUNT())
    code = VC.get(cap, VCP.cv_CAP_PROP_FOURCC())
    fourcc = fourcc_to_string(code)

    Logger.info(
      "VideoProducer: opened #{video_path} #{trunc(actual_w)}x#{trunc(actual_h)} @ #{Float.round(actual_fps * 1.0, 2)} fps, frames=#{trunc(frame_count)}, fourcc=#{fourcc} (#{trunc(code)})"
    )
  end

  defp fps_to_interval_ms(nil), do: 0
  defp fps_to_interval_ms(fps) when is_integer(fps) and fps > 0, do: trunc(1000 / fps)
  defp fps_to_interval_ms(_), do: 0

  defp maybe_sleep(0), do: :ok
  defp maybe_sleep(ms) when is_integer(ms) and ms > 0, do: Process.sleep(ms)

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
        expanded = resolve_media_path(path)

        case CameraCalibrator.load_from_file(expanded) do
          {:ok, calibration} ->
            Logger.info("VideoProducer: loaded calibration from #{expanded}")
            broadcast_message(
              {:calibration, calibration},
              SendSlam.CalibrationRegistry
            )
            Keyword.put(opts, :calibration, calibration)
          {:error, :enoent} ->
            Logger.info(
              "VideoProducer: calibration file #{expanded} not found; continuing without it"
            )

            opts

          {:error, reason} ->
            Logger.warning(
              "VideoProducer: failed to load calibration from #{expanded}: #{inspect(reason)}"
            )

            opts
        end

      {nil, nil} ->
        # If the caller didn't specify a calibration file, try the project's default
        # (priv/calibration/latest.json) so we can ship the current calibration.
        default_path = CameraCalibrator.default_output_path()
        opts = Keyword.put_new(opts, :calibration_file, default_path)
        expanded = resolve_media_path(default_path)

        case CameraCalibrator.load_from_file(expanded) do
          {:ok, calibration} ->
            Logger.info("VideoProducer: loaded calibration from #{expanded}")

            broadcast_message(
              {:calibration, calibration},
              SendSlam.CalibrationRegistry
            )

            Keyword.put(opts, :calibration, calibration)

          {:error, :enoent} ->
            Logger.info(
              "VideoProducer: default calibration file #{expanded} not found; continuing without it"
            )

            opts

          {:error, reason} ->
            Logger.warning(
              "VideoProducer: failed to load default calibration from #{expanded}: #{inspect(reason)}"
            )

            opts
        end

      _ ->
        opts
    end
  end

  defp resolve_media_path!(path) do
    resolved = resolve_media_path(path)

    if is_binary(resolved) and resolved != "" do
      resolved
    else
      raise ArgumentError, "expected :video_path to be a non-empty path"
    end
  end

  # Resolves paths robustly when the app is started from varying working directories.
  # - If `path` is absolute, use it as-is.
  # - If `path` is relative, first try `cwd`, then `app_dir`, then `priv`.
  defp resolve_media_path(path) when is_binary(path) and path != "" do
    if Path.type(path) == :absolute do
      path
    else
      cwd = File.cwd!()
      app_dir = Application.app_dir(:send_slam)
      priv_dir = Application.app_dir(:send_slam, "priv")

      candidates =
        [
          Path.expand(path, cwd),
          Path.expand(path, app_dir),
          Path.expand(path, priv_dir)
        ]

      Enum.find(candidates, hd(candidates), &File.exists?/1)
    end
  end

  defp resolve_media_path(other), do: other

  defp maybe_persist_calibration(calibration, opts) do
    case Keyword.get(opts, :calibration_file) do
      path when is_binary(path) and path != "" ->
        case CameraCalibrator.save_to_file(calibration, path) do
          {:ok, written_path} ->
            Logger.info("VideoProducer: wrote calibration to #{written_path}")

          {:error, reason} ->
            Logger.warning(
              "VideoProducer: unable to write calibration to #{path}: #{inspect(reason)}"
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
