defmodule SendSlam.Native.CameraProducer do
  use Rustler, otp_app: :send_slam, crate: "cameraproducer"

  def open_camera(_index, _width, _height, _fps), do: :erlang.nif_error(:nif_not_loaded)
  def read_frame(_resource), do: :erlang.nif_error(:nif_not_loaded)
end
