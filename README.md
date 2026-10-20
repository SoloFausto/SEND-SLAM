# SEND-SLAM
![SEND-SLAM Logo](https://github.com/SoloFausto/SEND-SLAM/blob/main/logo.png)

SEND-SLAM is a SLAM Framework that lets you add your own cameras and easily run a SLAM algorithm with those cameras.
The current supported configuration is ORB-SLAM 3 in a docker container with one single mono camera as the input.
The system is currently in a proof of concept status, mainly being done in the span of a semester as an independent research project for COSC 482.

## Setup Instructions (intended for Linux primarly)
1. Install both Elixir and Docker to your system
2. Clone the github repository
3. Open a terminal in the root of the project
4. Build the SLAM docker image with sudo `docker buildx build -t net-orbslam .` (it's going to take a while)
5. Enter the send_slam folder through your terminal
7. Get all the required dependencies with `mix deps.get`
8. Modify the application.ex to suit your hardware configuration (change the device index for your camera, resolution, fps, etc.)
9. Access the SEND-SLAM camera calibrator and slam visualizer through your browser in `localhost:4000`
10. Calibrate your camera by taking photos of a 9x6 checkerboard where each square is 25mm (use a site like https://calib.io/pages/camera-calibration-pattern-generator to create such pattern)
11. After calibration, the camera parameters are saved to `send_slam/priv/calibration/latest.json` by default, and you should start seeing tracking data from the algorithm.
12. You can connect your own application to the system through `ws://localhost:4000/client`.

## Client WebSocket protocol

The browser panel and external applications use the same `/client` WebSocket. A new
connection receives no camera or pose data until it subscribes. Send JSON text
messages to choose streams:

```json
{"type":"subscribe","streams":["camera","pose"]}
```

Use `{"type":"unsubscribe","streams":["camera"]}` to stop a stream. Each
subscription change returns a JSON `subscriptions` message listing the active
streams. The `camera` stream sends binary JPEG frames. The `pose` stream sends
JSON messages with `{"type":"pose","payload":...}`. A client may subscribe to
either stream independently.

To calibrate, send `{"type":"calibrate","frames":["data:image/jpeg;base64,..."]}`
with checkerboard images. The response is a JSON `calibration` message with
`status` set to `ok` or `error`. Invalid requests receive a JSON `error` message.


