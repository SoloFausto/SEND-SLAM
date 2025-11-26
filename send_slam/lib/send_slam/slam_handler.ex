defmodule SendSlam.SlamHandler do
  @moduledoc """
  ThousandIsland handler that forwards MessagePack-encoded frames to TCP clients.
  """
  use ThousandIsland.Handler
  require Logger
  alias Msgpax
  alias SendSlam.CalibrationCache

  @backend_registry SendSlam.BackendRegistry
  @pose_registry SendSlam.PoseRegistry
  @calibration_registry SendSlam.CalibrationRegistry

  def send_message(pid, msg) when is_binary(msg) do
    GenServer.cast(pid, {:send, msg})
  end

  @impl ThousandIsland.Handler
  def handle_connection(socket, handler_opts) do
    {:ok, {remote_address, remote_port}} = ThousandIsland.Socket.peername(socket)
    {:ok, _} = Registry.register(@backend_registry, :clients, %{})
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
  def handle_info({:msgpack_frame, payload}, {socket, state}) when is_binary(payload) do
    case ThousandIsland.Socket.send(socket, payload) do
      :ok -> {:noreply, {socket, state}, socket.read_timeout}
      {:error, reason} -> {:stop, reason, {socket, state}}
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
            Map.put(state, :last_calibration_digest, digest)

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
