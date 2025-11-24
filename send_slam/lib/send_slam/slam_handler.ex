defmodule SendSlam.SlamHandler do
  @moduledoc """
  ThousandIsland handler that forwards MessagePack-encoded frames to TCP clients.
  """
  use ThousandIsland.Handler
  require Logger

  @registry SendSlam.TcpClientRegistry

  def send_message(pid, msg) when is_binary(msg) do
    GenServer.cast(pid, {:send, msg})
  end

  @impl ThousandIsland.Handler
  def handle_connection(socket, handler_opts) do
    {:ok, {remote_address, remote_port}} = ThousandIsland.Socket.peername(socket)
    {:ok, _} = Registry.register(@registry, :clients, %{})
    info = format_remote(remote_address, remote_port)
    Logger.info("TCP client connected: #{info}")

    state =
      handler_opts
      |> Map.new()
      |> Map.put(:remote_address, remote_address)
      |> Map.put(:remote_port, remote_port)

    {:continue, state}
  end

  @impl ThousandIsland.Handler
  def handle_data(message, _socket, state) do
    Logger.debug("Inbound TCP payload (#{byte_size(message)} bytes) ignored")
    {:continue, state}
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
end
