# SEND-SLAM
![SEND-SLAM Logo](https://github.com/SoloFausto/SEND-SLAM/blob/main/logo.png)

SEND-SLAM is a SLAM Framework that lets you add your own cameras and easily run a SLAM algorithm with those cameras.
The current supported configuration is ORB-SLAM 3 in a docker container with one single mono camera as the input.
The system is currently in a proof of concept status, mainly being done in the span of a semester as an independent research project for a class.

## Setup Instructions (intended for Linux primarly)
1. Install both Elixir and Docker to your system
2. Clone the github repository
3. Open a terminal in the root of the project
4. Build the SLAM docker image with sudo docker buildx build -t net-orbslam . (it's going to take a while)
5. Enter the send_slam folder
7. Get all the required dependencies with mix deps.get
8. Modify the application.ex to suit your hardware configuration (change the device index for your camera, resolution, fps, etc.)
9. Access the camera calibrator/slam visualizer through your browser in localhost:4000
10. Calibrate your camera by taking photos of a 9x6 checkerboard where each square is 25mm (use a site like https://calib.io/pages/camera-calibration-pattern-generator to create such pattern)
11. After calibration, your pattern should be saved automatically in priv/calibration.json, and you should start seeing some tracking data from the algorithm.
12. You can connect your own application to the system by connecting to ws://localhost:4000/client through Websockets.


