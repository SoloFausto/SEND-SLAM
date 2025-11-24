defmodule SendSlam.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger
  require GenStage
  require ThousandIsland
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

    _ =
      DynamicSupervisor.start_child(
        SendSlam.Supervisor,
        {Registry, keys: :duplicate, name: SendSlam.BackendRegistry}
      )

    _ =
      DynamicSupervisor.start_child(
        SendSlam.Supervisor,
        {Registry, keys: :duplicate, name: SendSlam.TcpClientRegistry}
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

    # {:ok, cameraConsumerPid} =
    #   DynamicSupervisor.start_child(
    #     SendSlam.Supervisor,
    #     {SendSlam.ExampleConsumer, []}
    #   )

    {:ok, frameBroadcasterPid} =
      DynamicSupervisor.start_child(
        SendSlam.Supervisor,
        {SendSlam.FrameBroadcaster, []}
      )

    {:ok, pid} = ThousandIsland.start_link(port: 5000, handler_module: SendSlam.SlamHandler)

    {:ok, dockerHandlerPid} =
      DynamicSupervisor.start_child(
        SendSlam.Supervisor,
        {SendSlam.DockerHandler,
         [
           image: "net-orbslam",
           name: "net-orbslam",
           monitor_interval: 5_000,
           env: %{
             "ORBSLAM3_MAP_PATH" => System.get_env("ORBSLAM3_MAP_PATH") || "/data/maps"
           },
           auto_restart: true
         ]}
      )

    {:ok, imageConsumerPid} =
      DynamicSupervisor.start_child(
        SendSlam.Supervisor,
        {SendSlam.ImageConsumer, []}
      )

    GenServer.call(dockerHandlerPid, :start_container)

    {:ok, banditPid} =
      DynamicSupervisor.start_child(
        SendSlam.Supervisor,
        {Bandit, plug: SendSlam.WebServer, port: 4000}
      )

    # Subscribe the frame broadcaster to the camera producer to forward frames to WebSocket clients
    GenStage.sync_subscribe(frameBroadcasterPid, to: cameraProducerPid)
    # GenStage.sync_subscribe(cameraConsumerPid, to: cameraProducerPid)
    GenStage.sync_subscribe(imageConsumerPid, to: cameraProducerPid)

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
