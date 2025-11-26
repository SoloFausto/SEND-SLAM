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
    _ = Registry.register(SendSlam.CameraRegistry, :clients, %{})
    {:push, {:text, ""}, %{}}
  end

  # Receive broadcasted frames and push to this socket
  def handle_info({:camera_frame, {:ok, data}}, state) do
    with {:ok, frame} <- Keyword.fetch(data,:frame) do
      frame_binary = Cv.imencode(".jpeg", frame)
      {:push, {:binary, frame_binary}, state}
    end
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
        Logger.info("Calibration successful: #{inspect(calibration.camera_matrix)}")

        broadcast_message(
          {:calibration, calibration},
          SendSlam.CalibrationRegistry
        )

        {:push, {:text, "OK"}, state}

      {:error, reason} ->
        Logger.error("Calibration failed: #{inspect(reason)}")
        {:push, {:text, "ERROR"}, state}
    end
  end

  def terminate(_reason, _state) do
    :ok
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
