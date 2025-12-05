defmodule SendSlam.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger
  require ThousandIsland
  alias SendSlam.CameraCalibrator
  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: SendSlam.Supervisor]
    {:ok, _supervisor_pid} = DynamicSupervisor.start_link(opts)

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
        {Registry, keys: :duplicate, name: SendSlam.PoseRegistry}
      )

    _ =
      DynamicSupervisor.start_child(
        SendSlam.Supervisor,
        {Registry, keys: :duplicate, name: SendSlam.CameraRegistry}
      )

    {:ok, _camera_producer_pid} =
      DynamicSupervisor.start_child(
        SendSlam.Supervisor,
        {SendSlam.CameraProducer,
         [
           device_index: 4,
           width: 1280,
           height: 800,
           fps: 30,
           buffer_size: 0,
           calibration_file: CameraCalibrator.default_output_path()
         ]}
      )

    # {:ok, cameraConsumerPid} =
    #   DynamicSupervisor.start_child(
    #     SendSlam.Supervisor,
    #     {SendSlam.ExampleConsumer, []}
    #   )

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


    {:ok, _image_consumer_pid} =
      DynamicSupervisor.start_child(
        SendSlam.Supervisor,
        {SendSlam.ImageConsumer, []}
      )

    {:ok, _banditPid} =
      DynamicSupervisor.start_child(
        SendSlam.Supervisor,
        {Bandit, plug: SendSlam.WebServer, port: 4000}
      )

    {:ok, _pose_bandit_pid} =
      DynamicSupervisor.start_child(
        SendSlam.Supervisor,
        {Bandit, plug: SendSlam.PoseWebServer, port: 4001}
      )

    GenServer.call(dockerHandlerPid, :start_container)

    {:ok, pid}
  end
end
