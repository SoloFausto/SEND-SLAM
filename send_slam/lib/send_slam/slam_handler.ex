defmodule SlamHandler do
  @moduledoc """
  A simple ThousandIsland handler that echoes received messages back to the client.
  """
  use ThousandIsland.Handler

  def send_message(pid, msg) do
    GenServer.cast(pid, {:send, msg})
  end

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    {:ok, {remote_address, _port}} = ThousandIsland.Socket.peername(socket)
    IO.puts("#{inspect(self())} received connection from #{remote_address}")
    {:continue, state}
  end

  @impl ThousandIsland.Handler
  def handle_data(msg, _socket, state) do
    IO.puts("Received #{msg}")
    {:continue, state}
  end

  @impl GenServer
  def handle_cast({:send, msg}, {socket, state}) do
    ThousandIsland.Socket.send(socket, msg)
    {:noreply, {socket, state}, socket.read_timeout}
  end

  @impl GenServer
  def handle_info(_info, {socket, state}) do
    {:noreply, {socket, state}, socket.read_timeout}
  end
end
