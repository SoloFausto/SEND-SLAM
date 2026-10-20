defmodule SendSlam.ClientApplicationServerTest do
  use ExUnit.Case, async: false

  alias SendSlam.ClientApplicationServer, as: Client

  setup do
    start_supervised!({Registry, keys: :duplicate, name: SendSlam.CameraRegistry})
    start_supervised!({Registry, keys: :duplicate, name: SendSlam.PoseRegistry})
    {:ok, state} = Client.init([])
    %{state: state}
  end

  test "streams are silent until explicitly subscribed", %{state: state} do
    assert Registry.lookup(SendSlam.CameraRegistry, :clients) == []
    assert Registry.lookup(SendSlam.PoseRegistry, :clients) == []
    assert {:ok, ^state} = Client.handle_info({:broadcast_pose, %{position: %{x: 1}}}, state)
    assert {:ok, ^state} = Client.handle_info({:camera_frame, {:ok, [frame: :unused]}}, state)
  end

  test "subscribe and unsubscribe independently and idempotently", %{state: state} do
    {:push, {:text, camera_reply}, camera_state} =
      Client.handle_in({~s({"type":"subscribe","streams":["camera"]}), opcode: :text}, state)

    assert Jason.decode!(camera_reply) == %{"type" => "subscriptions", "streams" => ["camera"]}
    assert length(Registry.lookup(SendSlam.CameraRegistry, :clients)) == 1
    assert Registry.lookup(SendSlam.PoseRegistry, :clients) == []

    {:push, {:text, both_reply}, both_state} =
      Client.handle_in(
        {~s({"type":"subscribe","streams":["camera","pose"]}), opcode: :text},
        camera_state
      )

    assert Jason.decode!(both_reply) == %{
             "type" => "subscriptions",
             "streams" => ["camera", "pose"]
           }

    assert length(Registry.lookup(SendSlam.CameraRegistry, :clients)) == 1
    assert length(Registry.lookup(SendSlam.PoseRegistry, :clients)) == 1

    {:push, {:text, pose_json}, ^both_state} =
      Client.handle_info({:broadcast_pose, %{position: %{x: 1}}}, both_state)

    assert Jason.decode!(pose_json) == %{
             "type" => "pose",
             "payload" => %{"position" => %{"x" => 1}}
           }

    {:push, {:text, remaining_reply}, remaining_state} =
      Client.handle_in({~s({"type":"unsubscribe","streams":["pose"]}), opcode: :text}, both_state)

    assert Jason.decode!(remaining_reply) == %{"type" => "subscriptions", "streams" => ["camera"]}
    assert Registry.lookup(SendSlam.PoseRegistry, :clients) == []
    assert length(Registry.lookup(SendSlam.CameraRegistry, :clients)) == 1

    assert {:ok, ^remaining_state} =
             Client.handle_info({:broadcast_pose, %{position: %{x: 2}}}, remaining_state)
  end

  test "invalid requests do not alter subscriptions", %{state: state} do
    for request <- [
          ~s({"type":"subscribe","streams":["camera","unknown"]}),
          ~s({"type":"subscribe","streams":[]}),
          ~s({"type":"subscribe","streams":"pose"}),
          "not json"
        ] do
      assert {:push, {:text, reply}, ^state} = Client.handle_in({request, opcode: :text}, state)
      assert Jason.decode!(reply)["type"] == "error"
    end

    assert Registry.lookup(SendSlam.CameraRegistry, :clients) == []
    assert Registry.lookup(SendSlam.PoseRegistry, :clients) == []

    assert {:push, {:text, binary_reply}, ^state} =
             Client.handle_in(
               {~s({"type":"subscribe","streams":["pose"]}), opcode: :binary},
               state
             )

    assert Jason.decode!(binary_reply) == %{"type" => "error", "reason" => "invalid_message"}
  end

  test "invalid calibration frames return an error without crashing", %{state: state} do
    assert {:push, {:text, reply}, ^state} =
             Client.handle_in(
               {~s({"type":"calibrate","frames":["not base64!"]}), opcode: :text},
               state
             )

    assert Jason.decode!(reply) == %{
             "type" => "calibration",
             "status" => "error",
             "reason" => ":invalid_frame"
           }
  end
end
