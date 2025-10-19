#!/usr/bin/env elixir

# Simple example showing how to use the simplified CameraCalibrator
# This script captures frames and then calibrates in one go

Code.require_file("lib/send_slam/camera_calibrator.ex", Path.dirname(__DIR__))

alias Evision, as: Cv
alias SendSlam.CameraCalibrator

IO.puts("=== Simple Camera Calibration ===\n")

# Open camera
{:ok, cap} = Cv.VideoCapture.videoCapture(0)

IO.puts("Capturing frames with checkerboard pattern...")
IO.puts("Press ENTER to capture each frame (need 15-20 frames)")
IO.puts("Type 'done' when finished\n")

defmodule FrameCollector do
  def collect_frames(cap, frames \\ [], target \\ 15) do
    count = length(frames)

    if count >= target do
      IO.puts("\n#{count} frames captured!")
      frames
    else
      IO.write("Frames: #{count}/#{target} - Press ENTER to capture (or 'done'): ")
      input = IO.gets("") |> String.trim()

      case input do
        "done" ->
          IO.puts("\nFinished capturing #{count} frames")
          frames

        _ ->
          case Evision.VideoCapture.read(cap) do
            {:ok, frame} ->
              IO.puts("✓ Frame captured")
              collect_frames(cap, [frame | frames], target)

            {:error, reason} ->
              IO.puts("✗ Failed to read frame: #{inspect(reason)}")
              collect_frames(cap, frames, target)
          end
      end
    end
  end
end

# Collect frames
frames = FrameCollector.collect_frames(cap)

# Release camera
Cv.VideoCapture.release(cap)

# Perform calibration
IO.puts("\nCalibrating camera...")

case CameraCalibrator.calibrate(frames, pattern_size: {9, 6}, square_size: 25.0) do
  {:ok, calibration} ->
    IO.puts("\n=== Calibration Successful! ===")
    IO.puts("Successful frames: #{calibration.successful_frames}/#{length(frames)}")
    IO.puts("Reprojection error: #{calibration.reprojection_error}")
    IO.puts("\nCamera Matrix:")
    IO.inspect(calibration.camera_matrix)
    IO.puts("\nDistortion Coefficients:")
    IO.inspect(calibration.distortion_coeffs)

  {:error, reason} ->
    IO.puts("\n✗ Calibration failed: #{inspect(reason)}")
end
