defmodule SendSlam.CalibrationCache do
  @moduledoc """
  Simple persistent store for the most recent calibration packet produced by
  `SendSlam.ImageConsumer`. The cache is used to re-send calibration data to new
  backend connections without forcing the calibration workflow to run again.
  """

  @cache_key {__MODULE__, :latest}

  @doc """
  Persist the latest calibration packet (already length-prefixed MessagePack
  binary) alongside its digest for quick retrieval.
  """
  @spec put(binary(), term()) :: :ok
  def put(packet, digest) when is_binary(packet) do
    :persistent_term.put(@cache_key, {packet, digest})
    :ok
  end

  @doc """
  Fetch the cached calibration packet.
  Returns `{:ok, {packet, digest}}` when present, or `:error` if nothing has been cached yet.
  """
  @spec get() :: {:ok, {binary(), term()}} | :error
  def get do
    case :persistent_term.get(@cache_key, :undefined) do
      :undefined ->
        :error

      {packet, digest} when is_binary(packet) ->
        {:ok, {packet, digest}}

      other ->
        :persistent_term.erase(@cache_key)
        {:error, other}
    end
  end
end
