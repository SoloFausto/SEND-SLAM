defmodule SendSlam.ClientApplicationServer do
  @moduledoc """
  WebSocket client interface for explicitly subscribed camera and pose streams.

  Clients subscribe with `{"type":"subscribe","streams":["camera","pose"]}`.
  Camera frames are JPEG binary messages; poses are JSON text messages. Clients can
  submit calibration samples with `{"type":"calibrate","frames":[...]}`.
  """

  @behaviour WebSock

  require Logger
  alias Evision, as: Cv

  @camera_registry SendSlam.CameraRegistry
  @pose_registry SendSlam.PoseRegistry
  @calibration_registry SendSlam.CalibrationRegistry
  @streams %{"camera" => @camera_registry, "pose" => @pose_registry}

  def init(_opts), do: {:ok, %{subscriptions: MapSet.new()}}

  def handle_in({payload, [opcode: :text]}, state) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{"type" => "subscribe", "streams" => streams}} ->
        change_subscriptions(streams, :subscribe, state)

      {:ok, %{"type" => "unsubscribe", "streams" => streams}} ->
        change_subscriptions(streams, :unsubscribe, state)

      {:ok, %{"type" => "calibrate", "frames" => frames}} ->
        calibrate(frames, state)

      {:ok, _} ->
        error("unknown_request", state)

      {:error, _} ->
        error("invalid_json", state)
    end
  end

  def handle_in(_message, state), do: error("invalid_message", state)

  def handle_info({:camera_frame, {:ok, data}}, state) when is_list(data) do
    if MapSet.member?(state.subscriptions, "camera") do
      case Keyword.fetch(data, :frame) do
        {:ok, frame} -> {:push, {:binary, Cv.imencode(".jpeg", frame)}, state}
        :error -> {:ok, state}
      end
    else
      {:ok, state}
    end
  end

  def handle_info({:broadcast_pose, pose_map}, state) when is_map(pose_map) do
    if MapSet.member?(state.subscriptions, "pose") do
      push_json(%{type: "pose", payload: pose_map}, state)
    else
      {:ok, state}
    end
  end

  def handle_info(other, state) do
    Logger.debug("Client socket ignoring message: #{inspect(other)}")
    {:ok, state}
  end

  def terminate(_reason, _state), do: :ok

  defp change_subscriptions(streams, action, state) do
    if valid_streams?(streams) do
      subscriptions =
        Enum.reduce(streams, state.subscriptions, fn stream, current ->
          update_subscription(stream, action, current)
        end)

      push_json(
        %{type: "subscriptions", streams: subscriptions |> MapSet.to_list() |> Enum.sort()},
        %{state | subscriptions: subscriptions}
      )
    else
      error("invalid_streams", state)
    end
  end

  defp valid_streams?(streams) do
    is_list(streams) and streams != [] and
      Enum.all?(streams, &Map.has_key?(@streams, &1))
  end

  defp update_subscription(stream, :subscribe, subscriptions) do
    unless MapSet.member?(subscriptions, stream) do
      {:ok, _} = Registry.register(Map.fetch!(@streams, stream), :clients, %{})
    end

    MapSet.put(subscriptions, stream)
  end

  defp update_subscription(stream, :unsubscribe, subscriptions) do
    if MapSet.member?(subscriptions, stream) do
      Registry.unregister(Map.fetch!(@streams, stream), :clients)
    end

    MapSet.delete(subscriptions, stream)
  end

  defp calibrate(frames, state) when is_list(frames) and frames != [] do
    with {:ok, images} <- decode_frames(frames),
         {:ok, calibration} <- SendSlam.CameraCalibrator.calibrate(images) do
      Registry.dispatch(@calibration_registry, :clients, fn entries ->
        for {pid, _} <- entries, pid != self() do
          send(pid, {:broadcast_message, {:calibration, calibration}})
        end
      end)

      push_json(%{type: "calibration", status: "ok"}, state)
    else
      {:error, reason} ->
        Logger.warning("Calibration failed: #{inspect(reason)}")
        push_json(%{type: "calibration", status: "error", reason: inspect(reason)}, state)
    end
  end

  defp calibrate(_frames, state), do: error("invalid_frames", state)

  defp decode_frames(frames) do
    Enum.reduce_while(frames, {:ok, []}, fn encoded, {:ok, images} ->
      case decode_frame(encoded) do
        {:ok, image} -> {:cont, {:ok, [image | images]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, images} -> {:ok, Enum.reverse(images)}
      error -> error
    end
  end

  defp decode_frame(encoded) when is_binary(encoded) do
    base64 = Regex.replace(~r/^data:[^,]*;base64,/, encoded, "")

    with {:ok, bytes} <- Base.decode64(base64),
         %Evision.Mat{} = image <- Cv.imdecode(bytes, 1) do
      {:ok, image}
    else
      _ -> {:error, :invalid_frame}
    end
  end

  defp decode_frame(_), do: {:error, :invalid_frame}

  defp push_json(message, state) do
    {:push, {:text, Jason.encode!(message)}, state}
  end

  defp error(reason, state) do
    push_json(%{type: "error", reason: reason}, state)
  end
end
