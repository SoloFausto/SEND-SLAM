defmodule SendSlam.ClientApplicationServer do
  @moduledoc """
  WebSock handler that streams pose updates to browser clients.
  """

  @behaviour WebSock
  require Logger

  @pose_registry SendSlam.PoseRegistry

  def init(_opts) do
    _ = Registry.register(@pose_registry, :clients, %{})
    {:ok, %{}}
  end

  def handle_info({:broadcast_pose, pose_map}, state) when is_map(pose_map) do
    payload = Jason.encode!(%{type: "pose", payload: pose_map})
    {:push, {:text, payload}, state}
  end

  def handle_info(other, state) do
    Logger.debug("Client pose socket ignoring message: #{inspect(other)}")
    {:ok, state}
  end

  def handle_in(_message, state) do
    {:ok, state}
  end

  def terminate(_reason, _state) do
    :ok
  end
end
