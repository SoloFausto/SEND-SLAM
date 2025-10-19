defmodule SendSlam.ExampleConsumer do
  @moduledoc """
  A simple GenStage consumer that logs basic info about frames received.

  Not started by default; you can start it manually in IEx:

      {:ok, _} = GenStage.start_link(SendSlam.ExampleConsumer, subscribe_to: [SendSlam.CameraProducer])
  """

  use GenStage
  require Logger

  def start_link(_opts) do
    GenStage.start_link(__MODULE__, :ok)
  end

  @impl true
  def init(:ok) do
    {:consumer, :the_state_does_not_matter}
  end

  @impl true
  def handle_events(events, _from, state) do
    for event <- events do
      case event do
        {:ok, %Evision.Mat{} = mat} ->
          {h, w, c} = Evision.Mat.shape(mat) |> shape_to_tuple()
          Logger.info("Frame: #{w}x#{h}x#{c}")

        {:error, reason} ->
          Logger.warning("Frame error: #{inspect(reason)}")
      end
    end

    {:noreply, [], state}
  end

  @impl true
  defp shape_to_tuple({h, w, c}), do: {h, w, c}
  defp shape_to_tuple({h, w}), do: {h, w, 1}
end
