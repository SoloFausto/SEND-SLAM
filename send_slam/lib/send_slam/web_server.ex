defmodule SendSlam.WebServer do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/" do
    path = Path.expand("../../web/index.html", __DIR__)

    case File.read(path) do
      {:ok, html} ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html; charset=utf-8")
        |> send_resp(200, html)

      {:error, _} ->
        send_resp(conn, 404, "index.html not found")
    end
  end

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(SendSlam.WebSocketHandler, [], timeout: 60_000)
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end
end
