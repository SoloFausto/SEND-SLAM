defmodule SendSlam.ImageConsumer do
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
    {:ok, %{last_calibration_digest: nil}}
  end

  @impl true
  def handle_info({:camera_frame, event}, state) do
    {:noreply, process_event(event, state)}
  end

  def handle_info(other, state) do
    Logger.debug("ImageConsumer ignoring message: #{inspect(other)}")
    {:noreply, state}
  end

  defp process_event({:ok, opts}, state) when is_list(opts) do
    with {:ok, %Cv.Mat{} = mat} <- Keyword.fetch(opts, :frame),
         {:ok, dims} <- dimensions(mat),
         {:ok, jpeg} <- encode_to_jpeg(mat),
         {:ok, frame_packet} <- build_frame_packet(jpeg, dims, opts) do
      state = maybe_send_calibration(opts, dims, state)
      broadcast_packet(frame_packet)
      state
    else
      :error ->
        Logger.debug("Frame event missing :frame entry")
        state

      {:error, reason} ->
        Logger.warning("Unable to serialize frame: #{inspect(reason)}")
        state
    end
  end

  defp process_event({:error, reason}, state) do
    Logger.warning("Frame error: #{inspect(reason)}")
    state
  end

  defp process_event(other, state) do
    Logger.debug("Ignoring unexpected camera event: #{inspect(other)}")
    state
  end

  defp build_frame_packet(jpeg, dims, opts) when is_binary(jpeg) do
    camera_id = Keyword.get(opts, :camera_id, 1)
    timestamp = Keyword.get(opts, :timestamp, monotonic_seconds())

    payload = %{
      type: "frame",
      camera_id: camera_id,
      encoding: "jpeg",
      timestamp: timestamp,
      width: dims.width,
      height: dims.height,
      channels: dims.channels,
      frame: Msgpax.Bin.new(jpeg)
    }

    encode_payload(payload)
  end

  defp maybe_send_calibration(opts, dims, state) do
    case Keyword.get(opts, :calibration) do
      nil ->
        state

      calibration ->
        case build_calibration_packet(calibration, dims, opts) do
          {:ok, {packet, digest}} ->
            if state.last_calibration_digest == digest do
              state
            else
              cache_calibration(packet, digest)
              broadcast_packet(packet)
              %{state | last_calibration_digest: digest}
            end

          {:error, reason} ->
            Logger.warning("Unable to serialize calibration: #{inspect(reason)}")
            state
        end
    end
  end

  defp build_calibration_packet(calibration, dims, opts) do
    camera_id = Keyword.get(opts, :camera_id, 1)

    with {:ok, camera} <- calibration_camera_payload(calibration, dims, opts),
         {:ok, packet} <-
           encode_payload(%{
             type: "calibration",
             camera_id: camera_id,
             calibration: %{camera: camera}
           }) do
      digest = :erlang.phash2(camera)
      {:ok, {packet, digest}}
    end
  end

  defp calibration_camera_payload(calibration, dims, opts) do
    with {:ok, {fx, fy, cx, cy}} <- extract_intrinsics(calibration[:camera_matrix]),
         {:ok, {k1, k2, p1, p2}} <- extract_distortion(calibration[:distortion_coeffs]) do
      fps = Keyword.get(opts, :fps, 30)

      camera = %{
        type: "PinHole",
        fx: fx,
        fy: fy,
        cx: cx,
        cy: cy,
        k1: k1,
        k2: k2,
        p1: p1,
        p2: p2,
        width: dims.width,
        height: dims.height,
        fps: fps,
        rgb: 1,
        th_depth: 40.0,
        baseline: 0.0,
        depth_map_factor: 1000.0
      }

      {:ok, camera}
    end
  end

  defp extract_intrinsics(%Cv.Mat{} = mat) do
    case mat_to_list(mat) do
      {:error, _} = err ->
        err

      [fx, _, cx, _, fy, cy, _, _, _ | _rest] ->
        {:ok, {to_float(fx), to_float(fy), to_float(cx), to_float(cy)}}

      list when length(list) == 9 ->
        [fx, _, cx, _, fy, cy, _, _, _] = list
        {:ok, {to_float(fx), to_float(fy), to_float(cx), to_float(cy)}}

      other ->
        {:error, {:unexpected_camera_matrix, other}}
    end
  end

  defp extract_intrinsics(_), do: {:error, :missing_camera_matrix}

  defp extract_distortion(%Cv.Mat{} = mat) do
    case mat_to_list(mat) do
      {:error, _} = err ->
        err

      list when is_list(list) ->
        padded = list ++ List.duplicate(0.0, max(0, 4 - length(list)))
        [k1, k2, p1, p2 | _] = padded
        {:ok, {to_float(k1), to_float(k2), to_float(p1), to_float(p2)}}
    end
  end

  defp extract_distortion(_), do: {:error, :missing_distortion_coeffs}

  defp mat_to_list(%Cv.Mat{} = mat) do
    mat
    |> Cv.Mat.to_nx()
    |> Nx.to_flat_list()
  rescue
    e -> {:error, {:mat_to_nx_failed, e}}
  end

  defp encode_payload(payload) do
    try do
      binary =
        payload
        |> Msgpax.pack!()
        |> IO.iodata_to_binary()
        |> prepend_length()

      {:ok, binary}
    rescue
      e -> {:error, {:msgpack_encode_failed, e}}
    end
  end

  defp prepend_length(binary) when is_binary(binary) do
    <<byte_size(binary)::32-big-unsigned, binary::binary>>
  end

  defp monotonic_seconds do
    System.monotonic_time(:nanosecond) / 1_000_000_000
  end

  defp encode_to_jpeg(%Cv.Mat{} = mat) do
    try do
      {:ok, Cv.imencode(".jpg", mat)}
    rescue
      e -> {:error, {:jpeg_encode_failed, e}}
    end
  end

  defp dimensions(%Cv.Mat{} = mat) do
    case Cv.Mat.shape(mat) do
      {h, w, c} -> {:ok, %{height: h, width: w, channels: c}}
      {h, w} -> {:ok, %{height: h, width: w, channels: 1}}
      other -> {:error, {:unexpected_shape, other}}
    end
  end

  defp broadcast_packet(packet) do
    Registry.dispatch(@registry, :clients, fn entries ->
      for {pid, _} <- entries do
        send(pid, {:msgpack_frame, packet})
      end
    end)
  end

  defp cache_calibration(packet, digest) do
    CalibrationCache.put(packet, digest)
  end

  defp to_float(value) when is_number(value), do: value * 1.0
  defp to_float(_), do: 0.0
end
