defmodule SendSlam.PoseWebServer do
  @moduledoc """
  Thin Plug router that exposes the pose WebSocket on its own port.
  """

  use Plug.Router

  plug :match
  plug :dispatch

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(SendSlam.ClientApplicationServer, [], timeout: 60_000)
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end
end
