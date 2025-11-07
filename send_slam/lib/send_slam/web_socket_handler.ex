defmodule SendSlam.WebSocketHandler do
  @behaviour WebSock
  require Logger
  require SendSlam.CameraCalibrator
  require Jason
  alias Evision, as: Cv

  def init(_opts) do
    # Register this connection for broadcasting under a shared topic
    _ = Registry.register(SendSlam.WebSocketRegistry, :clients, %{})
    _ = Registry.register(SendSlam.CalibrationRegistry, :clients, %{})
    {:push, {:text, "Hello World! WebSocket connection established."}, %{}}
  end

  # Receive broadcasted frames and push to this socket
  def handle_info({:broadcast_frame, data}, state) do
    {:push, {:binary, data}, state}
  end

  def handle_in(message, state) do
    %{"calibrationFrames" => calibration_frames} = Jason.decode!(elem(message, 0))

    frames =
      Enum.map(calibration_frames, fn base64_str ->
        base64_str =
          String.replace_prefix(base64_str, "data:application/octet-stream;base64,", "")

        {:ok, bin} = Base.decode64(base64_str)
        Cv.imdecode(bin, 1)
      end)

    case SendSlam.CameraCalibrator.calibrate(frames) do
      {:ok, calibration} ->
        Logger.info("Calibration successful: #{inspect(calibration)}")

      {:error, reason} ->
        Logger.error("Calibration failed: #{inspect(reason)}")
    end

    {:push, {:text, "OK"}, state}
  end

  def terminate(_reason, _state) do
    :ok
  end

  # --- Internal helpers ---

  defp broadcast_frame(data) when is_binary(data) do
    from = self()

    Registry.dispatch(SendSlam.WebSocketRegistry, :clients, fn entries ->
      for {pid, _} <- entries, pid != from do
        send(pid, {:broadcast_frame, data})
      end
    end)

    :ok
  end
end
