#!/usr/bin/env elixir

Mix.install([
  {:evision, "~> 0.2.14"},
  {:nx, "~> 0.7"}
])

defmodule CalibrateCamera do
  @moduledoc """
  Simple module for camera calibration using checkerboard pattern detection.
  """

  use GenServer
  require Logger
  alias Evision, as: Cv

  defstruct [
    :cap,
    :pattern_size,
    :square_size,
    object_points: [],
    image_points: [],
    image_size: nil,
    calibration: nil
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def capture_frame(pid), do: GenServer.call(pid, :capture_frame, 10_000)
  def calibrate(pid), do: GenServer.call(pid, :calibrate, 30_000)
  def get_calibration(pid), do: GenServer.call(pid, :get_calibration)
  def get_frame_count(pid), do: GenServer.call(pid, :get_frame_count)

  @impl true
  def init(opts) do
    device = Keyword.get(opts, :device, 0)
    pattern_size = Keyword.get(opts, :pattern_size, {9, 6})
    square_size = Keyword.get(opts, :square_size, 25.0)
    device = Cv.VideoCapture.videoCapture(device)

    case Cv.VideoCapture.read(device) do
      {:ok, cap} ->
        state = %__MODULE__{
          cap: cap,
          pattern_size: pattern_size,
          square_size: square_size
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:capture_frame, _from, state) do
    case Cv.VideoCapture.read(state.cap) do
      {:ok, frame} ->
        case detect_checkerboard(frame, state.pattern_size) do
          {:ok, corners, gray} ->
            refined_corners = refine_corners(gray, corners, state.pattern_size)
            object_points = generate_object_points(state.pattern_size, state.square_size)
            {height, width, _} = Cv.Mat.shape(frame)
            image_size = {width, height}

            new_state = %{
              state
              | object_points: [object_points | state.object_points],
                image_points: [refined_corners | state.image_points],
                image_size: image_size
            }

            {:reply, {:ok, :detected}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, {:camera_read_failed, reason}}, state}
    end
  end

  @impl true
  def handle_call(:calibrate, _from, state) do
    frame_count = length(state.image_points)

    if frame_count < 10 do
      {:reply, {:error, {:insufficient_frames, frame_count}}, state}
    else
      object_points = Enum.reverse(state.object_points)
      image_points = Enum.reverse(state.image_points)

      case perform_calibration(object_points, image_points, state.image_size) do
        {:ok, calibration} ->
          new_state = %{state | calibration: calibration}
          {:reply, {:ok, calibration}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call(:get_calibration, _from, state) do
    case state.calibration do
      nil -> {:reply, {:error, :not_calibrated}, state}
      calibration -> {:reply, {:ok, calibration}, state}
    end
  end

  @impl true
  def handle_call(:get_frame_count, _from, state) do
    {:reply, length(state.image_points), state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.cap, do: Cv.VideoCapture.release(state.cap)
    :ok
  end

  defp detect_checkerboard(frame, {width, height}) do
    gray = Cv.cvtColor(frame, Cv.Constant.cv_COLOR_BGR2GRAY())

    case Cv.findChessboardCorners(gray, {width, height}) do
      {:ok, corners} -> {:ok, corners, gray}
      {:error, _} -> {:error, :pattern_not_found}
    end
  end

  defp refine_corners(gray, corners, _pattern_size) do
    criteria =
      Cv.TermCriteria.termCriteria(
        Cv.Constant.cv_TERM_CRITERIA_EPS() + Cv.Constant.cv_TERM_CRITERIA_MAX_ITER(),
        30,
        0.001
      )

    case Cv.cornerSubPix(gray, corners, {11, 11}, {-1, -1}, criteria) do
      {:ok, refined} -> refined
      {:error, _} -> corners
    end
  end

  defp generate_object_points({width, height}, square_size) do
    points =
      for y <- 0..(height - 1),
          x <- 0..(width - 1) do
        [x * square_size, y * square_size, 0.0]
      end

    points
    |> Nx.tensor(type: :f32)
    |> Cv.Mat.from_nx()
  end

  defp perform_calibration(object_points, image_points, {width, height}) do
    case Cv.calibrateCamera(
           object_points,
           image_points,
           {width, height},
           Cv.Mat.empty(),
           Cv.Mat.empty(),
           flags: 0
         ) do
      {:ok, {rms_error, camera_matrix, dist_coeffs, _rvecs, _tvecs}} ->
        calibration = %{
          camera_matrix: camera_matrix,
          distortion_coeffs: dist_coeffs,
          reprojection_error: rms_error
        }

        {:ok, calibration}

      {:error, reason} ->
        {:error, {:calibration_failed, reason}}
    end
  end
end

# Main script
IO.puts("=== Camera Calibration Tool ===")
IO.puts("This tool will help you calibrate your camera using a checkerboard pattern.")
IO.puts("You'll need a printed checkerboard with 9x6 inner corners.\n")

{:ok, pid} = CalibrateCamera.start_link(device: 0, pattern_size: {9, 6})

IO.puts("Starting calibration session...")
IO.puts("Point your camera at the checkerboard from different angles.")
IO.puts("Press ENTER to capture a frame, or type 'done' when finished.\n")

defmodule Capturer do
  def capture_loop(pid, target_frames \\ 15) do
    count = CalibrateCamera.get_frame_count(pid)

    if count >= target_frames do
      IO.puts("\n#{count} frames captured. Ready to calibrate!")
      :done
    else
      IO.write("Frames: #{count}/#{target_frames} - Press ENTER to capture (or 'done'): ")
      input = IO.gets("") |> String.trim()

      case input do
        "done" ->
          :done

        _ ->
          case CalibrateCamera.capture_frame(pid) do
            {:ok, :detected} ->
              IO.puts("✓ Pattern detected and captured!")
              capture_loop(pid, target_frames)

            {:error, :pattern_not_found} ->
              IO.puts("✗ Pattern not found. Adjust camera position.")
              capture_loop(pid, target_frames)

            {:error, reason} ->
              IO.puts("✗ Error: #{inspect(reason)}")
              capture_loop(pid, target_frames)
          end
      end
    end
  end
end

# Capture frames
Capturer.capture_loop(pid)

# Calibrate
IO.puts("\nPerforming calibration...")

case CalibrateCamera.calibrate(pid) do
  {:ok, calibration} ->
    IO.puts("\n=== Calibration Successful! ===")
    IO.puts("Reprojection Error: #{calibration.reprojection_error}")
    IO.puts("\nCamera Matrix:")
    IO.inspect(calibration.camera_matrix)
    IO.puts("\nDistortion Coefficients:")
    IO.inspect(calibration.distortion_coeffs)

  {:error, reason} ->
    IO.puts("\n✗ Calibration failed: #{inspect(reason)}")
end
