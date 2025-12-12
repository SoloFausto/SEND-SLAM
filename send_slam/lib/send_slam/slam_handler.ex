defmodule SendSlam.SlamHandler do
  @moduledoc """
  ThousandIsland handler that forwards MessagePack-encoded frames to TCP clients.
  """
  use ThousandIsland.Handler
  require Logger
  alias Msgpax
  alias SendSlam.CalibrationCache

  @camera_registry SendSlam.CameraRegistry
  @pose_registry SendSlam.PoseRegistry
  @calibration_registry SendSlam.CalibrationRegistry

  def send_message(pid, msg) when is_binary(msg) do
    GenServer.cast(pid, {:send, msg})
  end

  @impl ThousandIsland.Handler
  def handle_connection(socket, handler_opts) do
    {:ok, {remote_address, remote_port}} = ThousandIsland.Socket.peername(socket)
    {:ok, _} = Registry.register(@camera_registry, :clients, %{})
    {:ok, _} = Registry.register(@calibration_registry, :clients, %{})
    info = format_remote(remote_address, remote_port)
    Logger.info("TCP client connected: #{info}")

    state =
      handler_opts
      |> Map.new()
      |> Map.put(:remote_address, remote_address)
      |> Map.put(:remote_port, remote_port)
      |> Map.put(:recv_buffer, <<>>)
      |> Map.put(:last_calibration_digest, nil)
      |> Map.put(:calibration_sent, false)

    state = maybe_send_cached_calibration(socket, state)

    {:continue, state}
  end

  @impl ThousandIsland.Handler
  def handle_data(message, _socket, state) do
    buffer = state.recv_buffer <> message
    {packets, remainder} = extract_packets(buffer, [])

    Enum.each(packets, &handle_incoming_packet/1)

    {:continue, %{state | recv_buffer: remainder}}
  end

  @impl GenServer
  def handle_cast({:send, msg}, {socket, state}) when is_binary(msg) do
    case ThousandIsland.Socket.send(socket, msg) do
      :ok -> {:noreply, {socket, state}, socket.read_timeout}
      {:error, reason} -> {:stop, reason, {socket, state}}
    end
  end

  @impl GenServer
  def handle_info({:camera_frame, {:ok, opts}}, {socket, state}) when is_list(opts) do
    # Logger.info("My current mailbox size is #{inspect(Process.info(self(), :message_queue_len))}")
    start_ns = System.monotonic_time(:nanosecond)

    with {:ok, mat} <- Keyword.fetch(opts, :frame),
         {:ok, dims} <- dimensions(mat),
         {:ok, state} <- maybe_send_calibration_from_frame(socket, state, dims, opts),
         {:ok, ppm} <- encode_to_ppm(mat),
         {:ok, packet} <- build_frame_packet(ppm, dims, opts) do

      case ThousandIsland.Socket.send(socket, packet) do
        :ok ->
          log_timing("frame_ok", start_ns)
          {:noreply, {socket, state}, socket.read_timeout}
        {:error, reason} ->
          log_timing("frame_send_error", start_ns)
          {:stop, reason, {socket, state}}
      end
    else
      :error ->
        log_timing("frame_missing", start_ns)
        Logger.debug("SlamHandler: frame event missing :frame entry")
        {:noreply, {socket, state}, socket.read_timeout}

      {:error, reason} ->
        log_timing("frame_error", start_ns)
        Logger.warning("SlamHandler: unable to serialize frame: #{inspect(reason)}")
        {:noreply, {socket, state}, socket.read_timeout}
    end
  end

  def handle_info(info, {socket, state}) do
    Logger.debug("Unhandled message in SlamHandler: #{inspect(info)}")
    {:noreply, {socket, state}, socket.read_timeout}
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, state) do
    Logger.info(
      "TCP client disconnected: #{format_remote(state.remote_address, state.remote_port)}"
    )
  end

  @impl ThousandIsland.Handler
  def handle_error(reason, _socket, state) do
    Logger.warning(
      "TCP client error (#{format_remote(state.remote_address, state.remote_port)}): #{inspect(reason)}"
    )
  end

  defp format_remote(address, port) do
    ip = address |> :inet.ntoa() |> to_string()
    "#{ip}:#{port}"
  end

  defp extract_packets(buffer, acc) do
    case buffer do
      <<len::32-big-unsigned, rest::binary>> when byte_size(rest) >= len ->
        <<payload::binary-size(len), remainder::binary>> = rest
        extract_packets(remainder, [payload | acc])

      _ ->
        {Enum.reverse(acc), buffer}
    end
  end

  defp handle_incoming_packet(payload) do
    case Msgpax.unpack(payload, iodata: false) do
      {:ok, %{"type" => "pose"} = packet} ->
        broadcast_pose_packet(packet)
        # log_pose_packet(packet)

      {:ok, decoded} ->
        Logger.debug("Unhandled inbound packet: #{inspect(decoded)}")

      {:error, reason} ->
        Logger.warning("Failed to decode inbound MessagePack payload: #{inspect(reason)}")
    end
  end

  # Helpers to mirror ImageConsumer’s frame payload
  defp build_frame_packet(ppm, dims, opts) when is_binary(ppm) do
    camera_id = Keyword.get(opts, :camera_id, 1)
    timestamp = Keyword.get(opts, :timestamp, monotonic_seconds())

    payload = %{
      type: "frame",
      camera_id: camera_id,
      encoding: "ppm",
      timestamp: timestamp,
      width: dims.width,
      height: dims.height,
      channels: dims.channels,
      frame: Msgpax.Bin.new(ppm)
    }

    encode_payload(payload)
  end

  # Build and send calibration packet when frame includes calibration
  defp maybe_send_calibration_from_frame(socket, state, dims, opts) do
    case Keyword.get(opts, :calibration) do
      nil -> {:ok, state}

      calibration ->
        # Send calibration only once per connection
        if Map.get(state, :calibration_sent, false) do
          {:ok, state}
        else
          case build_calibration_packet(calibration, dims, opts) do
            {:ok, {packet, digest}} ->
              case ThousandIsland.Socket.send(socket, packet) do
                :ok ->
                  {:ok,
                   state
                   |> Map.put(:last_calibration_digest, digest)
                   |> Map.put(:calibration_sent, true)}
                {:error, reason} ->
                  Logger.warning("SlamHandler: failed to send calibration packet: #{inspect(reason)}")
                  {:ok, state}
              end

            {:error, reason} ->
              Logger.warning("SlamHandler: unable to serialize calibration: #{inspect(reason)}")
              {:ok, state}
          end
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

  defp extract_intrinsics(%Evision.Mat{} = mat) do
    case mat_to_list(mat) do
      {:error, _} = err -> err
      [fx, _, cx, _, fy, cy, _, _, _ | _rest] ->
        {:ok, {to_float(fx), to_float(fy), to_float(cx), to_float(cy)}}
      list when length(list) == 9 ->
        [fx, _, cx, _, fy, cy, _, _, _] = list
        {:ok, {to_float(fx), to_float(fy), to_float(cx), to_float(cy)}}
      other -> {:error, {:unexpected_camera_matrix, other}}
    end
  end
  defp extract_intrinsics(_), do: {:error, :missing_camera_matrix}

  defp extract_distortion(%Evision.Mat{} = mat) do
    case mat_to_list(mat) do
      {:error, _} = err -> err
      list when is_list(list) ->
        padded = list ++ List.duplicate(0.0, max(0, 4 - length(list)))
        [k1, k2, p1, p2 | _] = padded
        {:ok, {to_float(k1), to_float(k2), to_float(p1), to_float(p2)}}
    end
  end
  defp extract_distortion(_), do: {:error, :missing_distortion_coeffs}

  defp mat_to_list(%Evision.Mat{} = mat) do
    mat
    |> Evision.Mat.to_nx()
    |> Nx.to_flat_list()
  rescue
    e -> {:error, {:mat_to_nx_failed, e}}
  end

  defp to_float(value) when is_number(value), do: value * 1.0
  defp to_float(_), do: 0.0

  defp dimensions(%Evision.Mat{} = mat) do
    case Evision.Mat.shape(mat) do
      {h, w, c} -> {:ok, %{height: h, width: w, channels: c}}
      {h, w} -> {:ok, %{height: h, width: w, channels: 1}}
      other -> {:error, {:unexpected_shape, other}}
    end
  end

  defp encode_to_ppm(%Evision.Mat{} = mat) do
    try do
      {:ok, Evision.imencode(".ppm", mat)}
    rescue
      e -> {:error, {:ppm_encode_failed, e}}
    end
  end

  defp encode_payload(payload) do
    try do
      packed = Msgpax.pack!(payload)
      len = IO.iodata_length(packed)
      {:ok, [<<len::32-big-unsigned>>, packed]}
    rescue
      e -> {:error, {:msgpack_encode_failed, e}}
    end
  end

  defp monotonic_seconds do
    System.monotonic_time(:nanosecond) / 1_000_000_000
  end

  defp log_timing(label, start_ns) do
    elapsed_ms = (System.monotonic_time(:nanosecond) - start_ns) / 1_000_000
    Logger.info("SlamHandler #{label} in #{Float.round(elapsed_ms, 2)} ms")
  end

  defp log_pose_packet(%{"timestamp" => ts, "camera_id" => camera_id} = packet) do
    with %{"x" => x, "y" => y, "z" => z} <- Map.get(packet, "position") do
      Logger.info(
        "SLAM pose (camera #{camera_id}) @ #{format_float(ts)}s → pos: {#{format_float(x)}, #{format_float(y)}, #{format_float(z)}}"
      )
    else
      _ ->
        Logger.warning("Pose packet missing position data: #{inspect(packet)}")
    end

    :ok
  end

  defp log_pose_packet(packet) do
    Logger.warning("Pose packet missing metadata: #{inspect(packet)}")
  end

  defp broadcast_pose_packet(packet) when is_map(packet) do
    Registry.dispatch(@pose_registry, :clients, fn entries ->
      for {pid, _} <- entries do
        Logger.debug("Broadcasting pose packet to #{inspect(pid)}")
        send(pid, {:broadcast_pose, packet})
      end
    end)

    :ok
  end

  defp maybe_send_cached_calibration(socket, state) do
    case CalibrationCache.get() do
      {:ok, {packet, digest}} ->
        case ThousandIsland.Socket.send(socket, packet) do
          :ok ->
            state
            |> Map.put(:last_calibration_digest, digest)
            |> Map.put(:calibration_sent, true)

          {:error, reason} ->
            Logger.warning(
              "Failed to push cached calibration to #{format_remote(state.remote_address, state.remote_port)}: #{inspect(reason)}"
            )

            state
        end

      :error ->
        state

      {:error, reason} ->
        Logger.debug("Calibration cache unavailable: #{inspect(reason)}")
        state
    end
  end

  defp format_float(value) when is_number(value) do
    :erlang.float_to_binary(value, decimals: 4)
  end

  defp format_float(value), do: inspect(value)
end
