defmodule SendSlam.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger
  require GenStage

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: SendSlam.Supervisor]
    {:ok, pid} = DynamicSupervisor.start_link(opts)

    # Start a Registry to track WebSocket clients for broadcasting
    _ =
      DynamicSupervisor.start_child(
        SendSlam.Supervisor,
        {Registry, keys: :duplicate, name: SendSlam.WebSocketRegistry}
      )

    _ =
      DynamicSupervisor.start_child(
        SendSlam.Supervisor,
        {Registry, keys: :duplicate, name: SendSlam.CalibrationRegistry}
      )

    {:ok, cameraProducerPid} =
      DynamicSupervisor.start_child(
        SendSlam.Supervisor,
        {SendSlam.CameraProducer,
         [
           device_index: 0,
           width: 640,
           height: 480,
           fps: 30,
           buffer_size: 10
         ]}
      )

    {:ok, _cameraConsumerPid} =
      DynamicSupervisor.start_child(
        SendSlam.Supervisor,
        {SendSlam.ExampleConsumer, []}
      )

    {:ok, frameBroadcasterPid} =
      DynamicSupervisor.start_child(
        SendSlam.Supervisor,
        {SendSlam.FrameBroadcaster, []}
      )

    {:ok, banditPid} =
      DynamicSupervisor.start_child(
        SendSlam.Supervisor,
        {Bandit, plug: SendSlam.WebServer, port: 4000}
      )

    # Subscribe the frame broadcaster to the camera producer to forward frames to WebSocket clients
    GenStage.sync_subscribe(frameBroadcasterPid, to: cameraProducerPid)
    {:ok, pid}
  end

  defp maybe_camera_child do
    case System.get_env("SEND_SLAM_START_CAMERA") do
      "1" ->
        # Optionally pick device index/size from env
        device = System.get_env("SEND_SLAM_CAMERA_INDEX") || "0"
        width = System.get_env("SEND_SLAM_CAMERA_WIDTH") || "640"
        height = System.get_env("SEND_SLAM_CAMERA_HEIGHT") || "480"
        fps = System.get_env("SEND_SLAM_CAMERA_FPS") || "30"

        {SendSlam.CameraProducer,
         [
           device_index: String.to_integer(device),
           width: String.to_integer(width),
           height: String.to_integer(height),
           fps: String.to_integer(fps),
           buffer_size: 10
         ]}

      _ ->
        nil
    end
  end
end
