defmodule SendSlam.ExampleConsumer do
  @moduledoc """
  A simple GenStage consumer that logs basic info about frames received.

  Not started by default; you can start it manually in IEx:

      {:ok, _} = GenStage.start_link(SendSlam.ExampleConsumer, subscribe_to: [SendSlam.CameraProducer])
  """

  use GenStage
  require Logger
  alias Evision, as: Cv
  alias Msgpax

  @registry SendSlam.TcpClientRegistry

  def start_link(_opts) do
    GenStage.start_link(__MODULE__, :ok)
  end

  @impl true
  def init(:ok) do
    {:consumer, :the_state_does_not_matter}
  end

  @impl true
  def handle_events(events, _from, state) do
    Enum.each(events, &process_event/1)
    {:noreply, [], state}
  end

  defp process_event({:ok, opts}) when is_list(opts) do
    with {:ok, %Cv.Mat{} = mat} <- Keyword.fetch(opts, :frame),
         {:ok, packet} <- build_msgpack_payload(mat) do
      broadcast_packet(packet)
    else
      :error ->
        Logger.debug("Frame event missing :frame entry")

      {:error, reason} ->
        Logger.warning("Unable to serialize frame: #{inspect(reason)}")
    end
  end

  defp process_event({:error, reason}) do
    Logger.warning("Frame error: #{inspect(reason)}")
  end

  defp process_event(other) do
    Logger.debug("Ignoring unexpected camera event: #{inspect(other)}")
  end

  defp build_msgpack_payload(%Cv.Mat{} = mat) do
    with {:ok, jpeg} <- encode_to_jpeg(mat),
         {:ok, dims} <- dimensions(mat) do
      payload = %{
        type: "frame",
        encoding: "jpeg",
        timestamp_ms: System.os_time(:millisecond),
        width: dims.width,
        height: dims.height,
        channels: dims.channels,
        frame: jpeg
      }

      try do
        {:ok, Msgpax.pack!(payload)}
      rescue
        e -> {:error, {:msgpack_encode_failed, e}}
      end
    end
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
end
