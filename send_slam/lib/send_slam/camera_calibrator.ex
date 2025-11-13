defmodule SendSlam.CameraCalibrator do
  @moduledoc """
  Simple module for camera calibration using checkerboard pattern detection.

  Takes an array of frames and returns camera calibration parameters.

  ## Usage

      frames = [frame1, frame2, frame3, ...]

      result = SendSlam.CameraCalibrator.calibrate(frames,
        pattern_size: {9, 6},
        square_size: 25.0
      )

      case result do
        {:ok, cal} ->
          # Use calibration results
          IO.inspect(cal.camera_matrix)

        {:error, reason} ->
          IO.puts("Failed: \#{inspect(reason)}")
      end
      frames = [frame1, frame2, ...]

      {:ok, result} = SendSlam.CameraCalibrator.calibrate(frames)
  """

  require Logger
  alias Evision, as: Cv

  @type frame :: Evision.Mat.t()
  @type pattern_size :: {pos_integer(), pos_integer()}
  @type calibration_result :: %{
          camera_matrix: Evision.Mat.t(),
          distortion_coeffs: Evision.Mat.t(),
          reprojection_error: float(),
          successful_frames: non_neg_integer()
        }

  @doc """
  Calibrate camera from a list of frames containing checkerboard patterns.

  ## Parameters

  - `frames` - List of Evision.Mat frames to process
  - `opts` - Keyword list of options:
    - `:pattern_size` - Tuple {width, height} of inner corners (default: {9, 6})
    - `:square_size` - Size of checkerboard square in mm (default: 25.0)

  ## Returns

  - `{:ok, calibration}` - Calibration successful
  - `{:error, reason}` - Calibration failed

  ## Examples
      iex> SendSlam.CameraCalibrator.calibrate(frames)
      {:ok, %{camera_matrix: ..., distortion_coeffs: ..., reprojection_error: 0.42}}
  """
  @spec calibrate([frame()], keyword()) :: {:ok, calibration_result()} | {:error, term()}
  def calibrate(frames, opts \\ []) when is_list(frames) do
    pattern_size = Keyword.get(opts, :pattern_size, {9, 6})
    square_size = Keyword.get(opts, :square_size, 25.0)

    Logger.info("Processing #{length(frames)} frames for calibration...")

    # Detect patterns in all frames
    case detect_patterns_in_frames(frames, pattern_size, square_size) do
      {:ok, object_points, image_points, image_size, successful_count} ->
        if successful_count < 10 do
          {:error, {:insufficient_frames, successful_count}}
        else
          Logger.info(
            "Successfully detected patterns in #{successful_count}/#{length(frames)} frames"
          )

          perform_calibration(object_points, image_points, image_size, successful_count)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Process all frames and extract checkerboard corners
  defp detect_patterns_in_frames(frames, pattern_size, square_size) do
    results =
      frames
      |> Enum.with_index(1)
      |> Enum.map(fn {frame, idx} ->
        case detect_pattern_in_frame(frame, pattern_size, square_size) do
          {:ok, object_points, image_points, image_size} ->
            Logger.debug("Frame #{idx}: Pattern detected")
            {:ok, object_points, image_points, image_size}

          {:error, _reason} ->
            Logger.debug("Frame #{idx}: Pattern not found")
            :error
        end
      end)

    # Filter successful detections
    successful = Enum.filter(results, &match?({:ok, _, _, _}, &1))
    successful_count = length(successful)

    if successful_count == 0 do
      {:error, :no_patterns_detected}
    else
      # Extract the data from successful results
      {object_points, image_points, image_sizes} =
        Enum.reduce(successful, {[], [], []}, fn {:ok, obj_pts, img_pts, img_size},
                                                 {objs, imgs, sizes} ->
          {[obj_pts | objs], [img_pts | imgs], [img_size | sizes]}
        end)

      # Use the first image size (all should be the same)
      image_size = hd(image_sizes)

      {:ok, Enum.reverse(object_points), Enum.reverse(image_points), image_size, successful_count}
    end
  end

  # Detect checkerboard pattern in a single frame
  defp detect_pattern_in_frame(frame, pattern_size, square_size) do
    {width, height} = pattern_size

    # Convert to grayscale
    gray = Cv.cvtColor(frame, Cv.Constant.cv_COLOR_BGR2GRAY())

    # Find chessboard corners
    # Note: evision (OpenCV) may return different shapes depending on version:
    # - {true|false, corners_mat}
    # - {:ok, {true|false, corners_mat}}
    # - corners_mat (on success)
    case Cv.findChessboardCorners(gray, {width, height}) do
      {true, %Evision.Mat{} = corners} ->
        finish_detection(frame, gray, pattern_size, square_size, corners)

      {false, _} ->
        {:error, :pattern_not_found}

      {:ok, {true, %Evision.Mat{} = corners}} ->
        finish_detection(frame, gray, pattern_size, square_size, corners)

      {:ok, {false, _}} ->
        {:error, :pattern_not_found}

      # Some builds return the corners mat directly on success
      %Evision.Mat{} = corners ->
        finish_detection(frame, gray, pattern_size, square_size, corners)

      # Legacy wrappers may return {:ok, corners_mat}
      {:ok, %Evision.Mat{} = corners} ->
        finish_detection(frame, gray, pattern_size, square_size, corners)

      _other ->
        {:error, :pattern_not_found}
    end
  end

  # Complete the detection flow once corners are available
  defp finish_detection(frame, gray, pattern_size, square_size, corners) do
    # Refine corners to sub-pixel accuracy
    refined_corners = refine_corners(gray, corners)

    # Generate 3D object points
    object_points = generate_object_points(pattern_size, square_size)

    # Get image size
    {img_height, img_width, _} = Cv.Mat.shape(frame)
    image_size = {img_width, img_height}

    {:ok, object_points, refined_corners, image_size}
  end

  # Refine corner positions for better accuracy
  defp refine_corners(gray, corners) do
    # OpenCV/evision expects criteria as a 3-tuple: {type_flags, max_iter, epsilon}
    # Use EPS + MAX_ITER like cv2 docs: (EPS | MAX_ITER, 30, 1e-3)
    criteria = {
      Cv.Constant.cv_EPS() + Cv.Constant.cv_MAX_ITER(),
      30,
      0.001
    }

    case Cv.cornerSubPix(gray, corners, {11, 11}, {-1, -1}, criteria) do
      {:ok, %Evision.Mat{} = refined} -> refined
      %Evision.Mat{} = refined -> refined
      {:error, _} -> corners
      _ -> corners
    end
  end

  # Generate 3D object points for the checkerboard pattern
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

  # Perform camera calibration using collected points
  defp perform_calibration(object_points, image_points, {width, height}, successful_count) do
    Logger.info("Performing calibration with image size: #{width}x#{height}...")

    result =
      Cv.calibrateCamera(
        object_points,
        image_points,
        {width, height},
        Cv.Mat.empty(),
        Cv.Mat.empty(),
        flags: 0
      )

    case result do
      {:ok, {rms_error, camera_matrix, dist_coeffs, _rvecs, _tvecs}} ->
        build_calibration(rms_error, camera_matrix, dist_coeffs, successful_count)

      {rms_error, camera_matrix, dist_coeffs, _rvecs, _tvecs} ->
        build_calibration(rms_error, camera_matrix, dist_coeffs, successful_count)

      {:error, reason} ->
        {:error, {:calibration_failed, reason}}

      other ->
        {:error, {:unexpected_calibrate_return, other}}
    end
  end

  defp build_calibration(rms_error, camera_matrix, dist_coeffs, successful_count) do
    calibration = %{
      camera_matrix: camera_matrix,
      distortion_coeffs: dist_coeffs,
      reprojection_error: rms_error,
      successful_frames: successful_count
    }

    Logger.info("Calibration successful! RMS error: #{rms_error}")
    {:ok, calibration}
  end
end
