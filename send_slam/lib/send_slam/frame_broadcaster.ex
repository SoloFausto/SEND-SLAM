defmodule SendSlam.FrameBroadcaster do
  @moduledoc """
  GenStage consumer that receives frames from `SendSlam.CameraProducer`
  and broadcasts them to all connected WebSocket clients via `Registry`.

  Frames are encoded to JPEG binary before broadcasting.
  """

  use GenStage
  require Logger
  alias Evision, as: Cv

  def start_link(opts \\ []) do
    GenStage.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    {:consumer, %{}, subscribe_to: []}
  end

  @impl true
  def handle_events(events, _from, state) do
    Enum.each(events, fn
      {:ok, frame: %Cv.Mat{} = mat} ->
        case encode_to_jpeg(mat) do
          {:ok, bin} -> broadcast_bin(bin)
          {:error, reason} -> Logger.warning("Failed to encode frame: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("Camera frame error: #{inspect(reason)}")

      other ->
        Logger.debug("Ignoring unexpected event: #{inspect(other)}")
    end)

    {:noreply, [], state}
  end

  # --- Internal helpers ---

  defp encode_to_jpeg(%Cv.Mat{} = mat) do
    # Robustly normalize different return shapes from evision.imencode/2 or /3
    try do
      bin = Cv.imencode(".jpg", mat)
      {:ok, bin}
    rescue
      e -> {:error, {:imencode_failed, e}}
    end
  end

  defp broadcast_bin(bin) when is_binary(bin) do
    Registry.dispatch(SendSlam.WebSocketRegistry, :clients, fn entries ->
      for {pid, _} <- entries do
        send(pid, {:broadcast_frame, bin})
      end
    end)
  end
end
