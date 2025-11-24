/**
 * This file is part of ORB-SLAM3
 *
 * Copyright (C) 2017-2021 Carlos Campos, Richard Elvira, Juan J. Gómez Rodríguez, José M.M. Montiel and Juan D. Tardós, University of Zaragoza.
 * Copyright (C) 2014-2016 Raúl Mur-Artal, José M.M. Montiel and Juan D. Tardós, University of Zaragoza.
 *
 * ORB-SLAM3 is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
 * License as published by the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * ORB-SLAM3 is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
 * the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with ORB-SLAM3.
 * If not, see <http://www.gnu.org/licenses/>.
 */

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <numeric>
#include <stdexcept>
#include <string>
#include <sstream>
#include <system_error>
#include <vector>

#include <opencv2/core/core.hpp>
#include <opencv2/imgcodecs.hpp>

#include <Eigen/Core>
#include <Eigen/Geometry>

#include <System.h>
#include <Tracking.h>
#include <msgpack.hpp>
#include <sophus/se3.hpp>

#include <boost/asio.hpp>
#include <boost/system/error_code.hpp>
#include <boost/system/system_error.hpp>

#include <unistd.h>

using namespace std;

using tcp = boost::asio::ip::tcp;

namespace
{
        struct CameraCalibration
        {
                string type;
                double fx = 0.0;
                double fy = 0.0;
                double cx = 0.0;
                double cy = 0.0;
                double k1 = 0.0;
                double k2 = 0.0;
                double p1 = 0.0;
                double p2 = 0.0;
                int width = 0;
                int height = 0;
                double fps = 0.0;
                int rgb = 0;
                double stereoThDepth = 0.0;
                double stereoBaseline = 0.0;
                double depthMapFactor = 0.0;
        };
        struct MessagePacket
        {
                string type;
                vector<uint8_t> imageData;
                double timestamp = 0.0;
                bool hasImage = false;
                bool hasTimestamp = false;
                int camera_id = 0;
                bool hasCalibrationParameters = false;
                CameraCalibration calibrationParameters;
        };

        template <typename T>
        T RequireScalar(const map<string, msgpack::object> &node, const string &section, const string &key)
        {
                const auto it = node.find(key);
                if (it == node.end())
                {
                        throw runtime_error("Calibration section '" + section + "' is missing key '" + key + "'");
                }

                try
                {
                        return it->second.as<T>();
                }
                catch (const exception &ex)
                {
                        throw runtime_error("Failed to parse key '" + section + "." + key + "': " + string(ex.what()));
                }
        }

        CameraCalibration ParseCameraCalibration(const msgpack::object &obj)
        {
                if (obj.type != msgpack::type::MAP)
                {
                        throw runtime_error("Calibration 'camera' field must be a map");
                }

                map<string, msgpack::object> node;
                obj.convert(node);

                CameraCalibration camera;
                camera.type = RequireScalar<string>(node, "camera", "type");
                camera.fx = RequireScalar<double>(node, "camera", "fx");
                camera.fy = RequireScalar<double>(node, "camera", "fy");
                camera.cx = RequireScalar<double>(node, "camera", "cx");
                camera.cy = RequireScalar<double>(node, "camera", "cy");
                camera.k1 = RequireScalar<double>(node, "camera", "k1");
                camera.k2 = RequireScalar<double>(node, "camera", "k2");
                camera.p1 = RequireScalar<double>(node, "camera", "p1");
                camera.p2 = RequireScalar<double>(node, "camera", "p2");
                camera.width = RequireScalar<int>(node, "camera", "width");
                camera.height = RequireScalar<int>(node, "camera", "height");
                camera.fps = RequireScalar<double>(node, "camera", "fps");
                camera.rgb = RequireScalar<int>(node, "camera", "rgb");
                camera.stereoThDepth = RequireScalar<double>(node, "camera", "th_depth");
                camera.stereoBaseline = RequireScalar<double>(node, "camera", "baseline");
                camera.depthMapFactor = RequireScalar<double>(node, "camera", "depth_map_factor");
                return camera;
        }

        CameraCalibration ParseCalibrationParameters(const msgpack::object &obj)
        {
                if (obj.type != msgpack::type::MAP)
                {
                        throw runtime_error("Calibration payload must be a map");
                }

                map<string, msgpack::object> root;
                obj.convert(root);

                const auto it = root.find("camera");
                if (it != root.end())
                {
                        return ParseCameraCalibration(it->second);
                }

                return ParseCameraCalibration(obj);
        }

        string BuildCalibrationYaml(const CameraCalibration &camera)
        {
                ostringstream oss;
                oss << "%YAML:1.0\n\n";
                oss << "#--------------------------------------------------------------------------------------------\n";
                oss << "# Camera Parameters. Adjust them!\n";
                oss << "#--------------------------------------------------------------------------------------------\n";
                oss << "File.version: \"1.0\"\n\n";
                oss << "Camera.type: \"" << camera.type << "\"\n\n";
                oss << "# Right Camera calibration and distortion parameters (OpenCV)\n";
                oss << "Camera1.fx: " << camera.fx << "\n";
                oss << "Camera1.fy: " << camera.fy << "\n";
                oss << "Camera1.cx: " << camera.cx << "\n";
                oss << "Camera1.cy: " << camera.cy << "\n\n";
                oss << "# distortion parameters\n";
                oss << "Camera1.k1: " << camera.k1 << "\n";
                oss << "Camera1.k2: " << camera.k2 << "\n";
                oss << "Camera1.p1: " << camera.p1 << "\n";
                oss << "Camera1.p2: " << camera.p2 << "\n\n";
                oss << "# Camera resolution\n";
                oss << "Camera.width: " << camera.width << "\n";
                oss << "Camera.height: " << camera.height << "\n\n";
                oss << "# Camera frames per second \n";
                oss << "Camera.fps: " << camera.fps << "\n\n";
                oss << "# Color order of the images (0: BGR, 1: RGB. It is ignored if images are grayscale)\n";
                oss << "Camera.RGB: " << camera.rgb << "\n\n";
                oss << "Stereo.ThDepth: " << camera.stereoThDepth << "\n";
                oss << "Stereo.b: " << camera.stereoBaseline << "\n\n";
                oss << "# Depth map values factor\n";
                oss << "RGBD.DepthMapFactor: " << camera.depthMapFactor << "\n\n";
                oss << R"(# Transformation from body-frame (imu) to left camera
#--------------------------------------------------------------------------------------------
# ORB Parameters
#--------------------------------------------------------------------------------------------
# ORB Extractor: Number of features per image
ORBextractor.nFeatures: 1250

# ORB Extractor: Scale factor between levels in the scale pyramid 	
ORBextractor.scaleFactor: 1.2

# ORB Extractor: Number of levels in the scale pyramid	
ORBextractor.nLevels: 8

# ORB Extractor: Fast threshold
# Image is divided in a grid. At each cell FAST are extracted imposing a minimum response.
# Firstly we impose iniThFAST. If no corners are detected we impose a lower value minThFAST
# You can lower these values if your images have low contrast			
ORBextractor.iniThFAST: 20
ORBextractor.minThFAST: 7

#--------------------------------------------------------------------------------------------
# Viewer Parameters
#--------------------------------------------------------------------------------------------
Viewer.KeyFrameSize: 0.05
Viewer.KeyFrameLineWidth: 1.0
Viewer.GraphLineWidth: 0.9
Viewer.PointSize: 2.0
Viewer.CameraSize: 0.08
Viewer.CameraLineWidth: 3.0
Viewer.ViewpointX: 0.0
Viewer.ViewpointY: -0.7
Viewer.ViewpointZ: -3.5
Viewer.ViewpointF: 500.0
)";
                return oss.str();
        }

        bool SendPosePacket(tcp::socket &socket, const Sophus::SE3f &Tcw, double timestamp, int cameraId, int trackingState)
        {
                try
                {
                        const Sophus::SE3f Twc = Tcw.inverse();
                        const Eigen::Vector3f position = Twc.translation();
                        const Eigen::Quaternionf orientation = Twc.unit_quaternion();

                        msgpack::sbuffer buffer;
                        msgpack::packer packer(buffer);

                        packer.pack_map(6);
                        packer.pack("type");
                        packer.pack("pose");
                        packer.pack("timestamp");
                        packer.pack(timestamp);
                        packer.pack("camera_id");
                        packer.pack(cameraId);
                        packer.pack("tracking_state");
                        packer.pack(trackingState);

                        packer.pack("position");
                        packer.pack_map(3);
                        packer.pack("x");
                        packer.pack(static_cast<double>(position.x()));
                        packer.pack("y");
                        packer.pack(static_cast<double>(position.y()));
                        packer.pack("z");
                        packer.pack(static_cast<double>(position.z()));

                        packer.pack("orientation");
                        packer.pack_map(4);
                        packer.pack("x");
                        packer.pack(static_cast<double>(orientation.x()));
                        packer.pack("y");
                        packer.pack(static_cast<double>(orientation.y()));
                        packer.pack("z");
                        packer.pack(static_cast<double>(orientation.z()));
                        packer.pack("w");
                        packer.pack(static_cast<double>(orientation.w()));

                        const uint32_t messageLength = static_cast<uint32_t>(buffer.size());
                        const array<uint8_t, 4> header{
                            static_cast<uint8_t>((messageLength >> 24) & 0xFF),
                            static_cast<uint8_t>((messageLength >> 16) & 0xFF),
                            static_cast<uint8_t>((messageLength >> 8) & 0xFF),
                            static_cast<uint8_t>(messageLength & 0xFF)};

                        boost::asio::write(socket, boost::asio::buffer(header));
                        boost::asio::write(socket, boost::asio::buffer(buffer.data(), buffer.size()));
                        return true;
                }
                catch (const exception &ex)
                {
                        cerr << "Failed to send pose packet: " << ex.what() << endl;
                }
                return false;
        }

        bool ParseMessage(const vector<uint8_t> &payload, MessagePacket &packet)
        {
                msgpack::object_handle handle = msgpack::unpack(reinterpret_cast<const char *>(payload.data()), payload.size());
                const msgpack::object &root = handle.get();

                if (root.type != msgpack::type::MAP)
                {
                        throw runtime_error("MessagePack payload must be a map at the top level");
                }

                const auto &map = root.via.map;
                for (uint32_t i = 0; i < map.size; ++i)
                {
                        string key;
                        map.ptr[i].key.convert(key);

                        const msgpack::object &value = map.ptr[i].val;

                        if (key == "type")
                        {
                                value.convert(packet.type);
                        }
                        else if (key == "calibration" || key == "calibration_params")
                        {
                                packet.calibrationParameters = ParseCalibrationParameters(value);
                                packet.hasCalibrationParameters = true;
                        }
                        else if (key == "timestamp")
                        {
                                value.convert(packet.timestamp);
                                packet.hasTimestamp = true;
                        }
                        else if (key == "image" || key == "frame")
                        {
                                if (value.type != msgpack::type::BIN)
                                {
                                        throw runtime_error("Image data must be encoded as MessagePack bin");
                                }

                                const auto &bin = value.via.bin;
                                const auto *begin = reinterpret_cast<const uint8_t *>(bin.ptr);
                                packet.imageData.assign(begin, begin + bin.size);
                                packet.hasImage = true;
                        }
                        else if (key == "camera_id")
                        {
                                value.convert(packet.camera_id);
                        }
                        else
                        {
                                // Ignore other fields.
                        }
                }

                return !packet.type.empty();
        }
}

int main(int argc, char **argv)
{
        const string vocabularyPath = "/app/ORB_SLAM3/Vocabulary/ORBvoc.txt";

        const char *portEnv = std::getenv("ORB_SLAM3_WS_PORT");
        if (portEnv == nullptr)
        {
                cerr << "ORB_SLAM3_WS_PORT environment variable is not set." << endl;
                return 1;
        }

        int port = 0;
        try
        {
                port = stoi(portEnv);
        }
        catch (const exception &e)
        {
                cerr << "Failed to parse ORB_SLAM3_WS_PORT: " << e.what() << endl;
                return 1;
        }

        if (port <= 0 || port > 65535)
        {
                cerr << "ORB_SLAM3_WS_PORT must be a valid TCP port (1-65535)." << endl;
                return 1;
        }

        const string portStr = to_string(port);

        unique_ptr<ORB_SLAM3::System> pSLAM;
        vector<float> vTimesTrack;
        double previousTimestamp = -1.0;
        filesystem::path tempSettingsPath;

        cout << endl
             << "-------" << endl;
        cout << "Connecting to tcp://127.0.0.1:" << portStr << " ..." << endl;

        try
        {
                boost::asio::io_context ioContext;
                tcp::resolver resolver(ioContext);
                tcp::socket socket(ioContext);

                const auto results = resolver.resolve("127.0.0.1", portStr);
                boost::asio::connect(socket, results);

                auto readExact = [&socket](uint8_t *dst, size_t length) -> bool
                {
                        size_t total = 0;
                        while (total < length)
                        {
                                boost::system::error_code ec;
                                const size_t bytesRead = socket.read_some(boost::asio::buffer(dst + total, length - total), ec);
                                if (ec)
                                {
                                        if (ec == boost::asio::error::eof)
                                        {
                                                if (total == 0)
                                                        return false;
                                                throw runtime_error("Unexpected EOF while reading from TCP socket");
                                        }
                                        throw boost::system::system_error(ec);
                                }
                                total += bytesRead;
                        }
                        return true;
                };

                constexpr size_t kMaxMessageSize = 50 * 1024 * 1024; // 50 MB safety guard.

                bool calibrationReceived = false;
                float imageScale = 1.f;

                pSLAM.reset();
                vTimesTrack.clear();
                previousTimestamp = -1.0;

                cout << "Connection established. Awaiting calibration parameters..." << endl;

                while (true)
                {
                        array<uint8_t, 4> lengthBuffer{};
                        if (!readExact(lengthBuffer.data(), lengthBuffer.size()))
                        {
                                cout << "Connection closed by server." << endl;
                                break;
                        }

                        const uint32_t messageLength = (static_cast<uint32_t>(lengthBuffer[0]) << 24) |
                                                       (static_cast<uint32_t>(lengthBuffer[1]) << 16) |
                                                       (static_cast<uint32_t>(lengthBuffer[2]) << 8) |
                                                       static_cast<uint32_t>(lengthBuffer[3]);

                        if (messageLength == 0)
                        {
                                cerr << "Received empty MessagePack payload. Skipping." << endl;
                                continue;
                        }

                        if (messageLength > kMaxMessageSize)
                        {
                                cerr << "Message exceeds safety limit (" << messageLength << " bytes)." << endl;
                                return 1;
                        }

                        vector<uint8_t> payload(messageLength);
                        if (!readExact(payload.data(), payload.size()))
                        {
                                cerr << "Connection closed before full message was received." << endl;
                                break;
                        }

                        MessagePacket packet;
                        try
                        {
                                if (!ParseMessage(payload, packet))
                                {
                                        cerr << "Ignoring MessagePack payload without 'type' field." << endl;
                                        continue;
                                }
                        }
                        catch (const exception &ex)
                        {
                                cerr << "Failed to parse MessagePack payload: " << ex.what() << endl;
                                continue;
                        }

                        if (packet.type == "terminate" || packet.type == "shutdown")
                        {
                                cout << "Received termination request from server." << endl;
                                break;
                        }

                        if (packet.type == "calibration")
                        {
                                if (!packet.camera_id)
                                {
                                        cerr << "Calibration message missing camera identifier." << endl;
                                        continue;
                                }

                                if (!packet.hasCalibrationParameters)
                                {
                                        cerr << "Calibration message missing structured parameter payload." << endl;
                                        continue;
                                }

                                const string calibrationContents = BuildCalibrationYaml(packet.calibrationParameters);

                                if (!tempSettingsPath.empty())
                                {
                                        std::error_code removeEc;
                                        filesystem::remove(tempSettingsPath, removeEc);
                                        tempSettingsPath.clear();
                                }

                                const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
                                const filesystem::path tempFileName = "orbslam_ws_settings-" + std::to_string(stamp) + ".yaml";
                                tempSettingsPath = filesystem::temp_directory_path() / tempFileName;
                                ofstream settingsFile(tempSettingsPath);
                                if (!settingsFile.is_open())
                                {
                                        cerr << "Failed to create temporary settings file at " << tempSettingsPath << endl;
                                        return 1;
                                }
                                settingsFile << calibrationContents;
                                settingsFile.close();
                                pSLAM = make_unique<ORB_SLAM3::System>(vocabularyPath, tempSettingsPath.string(), ORB_SLAM3::System::MONOCULAR, false);
                                imageScale = pSLAM->GetImageScale();
                                calibrationReceived = true;
                                vTimesTrack.clear();
                                previousTimestamp = -1.0;

                                cout << "Calibration parameters received. SLAM system ready to process frames." << endl;
                                continue;
                        }

                        if (packet.type == "frame")
                        {
                                if (!calibrationReceived)
                                {
                                        cerr << "Received frame before calibration. Ignoring." << endl;
                                        continue;
                                }
                                if (!packet.camera_id)
                                {
                                        cerr << "Frame message missing camera identifier." << endl;
                                        continue;
                                }

                                if (!packet.hasImage || packet.imageData.empty())
                                {
                                        cerr << "Frame message missing binary image data." << endl;
                                        continue;
                                }

                                if (!packet.hasTimestamp)
                                {
                                        cerr << "Frame message missing timestamp." << endl;
                                        continue;
                                }

                                cv::Mat im = cv::imdecode(packet.imageData, cv::IMREAD_UNCHANGED);
                                if (im.empty())
                                {
                                        cerr << "Failed to decode frame image data." << endl;
                                        continue;
                                }

                                double t_resize = 0.0;
                                double t_track = 0.0;

                                if (imageScale != 1.f)
                                {
#ifdef REGISTER_TIMES
#ifdef COMPILEDWITHC23
                                        std::chrono::steady_clock::time_point t_Start_Resize = std::chrono::steady_clock::now();
#else
                                        std::chrono::monotonic_clock::time_point t_Start_Resize = std::chrono::monotonic_clock::now();
#endif
#endif
                                        const int width = static_cast<int>(im.cols * imageScale);
                                        const int height = static_cast<int>(im.rows * imageScale);
                                        cv::resize(im, im, cv::Size(width, height));
#ifdef REGISTER_TIMES
#ifdef COMPILEDWITHC23
                                        std::chrono::steady_clock::time_point t_End_Resize = std::chrono::steady_clock::now();
#else
                                        std::chrono::monotonic_clock::time_point t_End_Resize = std::chrono::monotonic_clock::now();
#endif
                                        t_resize = std::chrono::duration_cast<std::chrono::duration<double, std::milli>>(t_End_Resize - t_Start_Resize).count();
                                        if (pSLAM)
                                        {
                                                pSLAM->InsertResizeTime(t_resize);
                                        }
#endif
                                }

                                if (!pSLAM)
                                {
                                        cerr << "SLAM system is not initialized. Skipping frame." << endl;
                                        continue;
                                }

#ifdef COMPILEDWITHC23
                                std::chrono::steady_clock::time_point t1 = std::chrono::steady_clock::now();
#else
                                std::chrono::monotonic_clock::time_point t1 = std::chrono::monotonic_clock::now();
#endif

                                const Sophus::SE3f Tcw = pSLAM->TrackMonocular(im, packet.timestamp);
                                const int trackingState = pSLAM->GetTrackingState();
                                if (trackingState == ORB_SLAM3::Tracking::OK)
                                {
                                        SendPosePacket(socket, Tcw, packet.timestamp, packet.camera_id, trackingState);
                                }

#ifdef COMPILEDWITHC23
                                std::chrono::steady_clock::time_point t2 = std::chrono::steady_clock::now();
#else
                                std::chrono::monotonic_clock::time_point t2 = std::chrono::monotonic_clock::now();
#endif

#ifdef REGISTER_TIMES
                                t_track = t_resize + std::chrono::duration_cast<std::chrono::duration<double, std::milli>>(t2 - t1).count();
                                if (pSLAM)
                                {
                                        pSLAM->InsertTrackTime(t_track);
                                }
#endif

                                const double ttrack = std::chrono::duration_cast<std::chrono::duration<double>>(t2 - t1).count();
                                vTimesTrack.push_back(static_cast<float>(ttrack));

                                if (previousTimestamp > 0.0)
                                {
                                        const double interval = packet.timestamp - previousTimestamp;
                                        if (ttrack < interval)
                                                usleep(static_cast<useconds_t>((interval - ttrack) * 1e6));
                                }
                                previousTimestamp = packet.timestamp;

                                continue;
                        }

                        cerr << "Received MessagePack with unsupported type: '" << packet.type << "'." << endl;
                }

                boost::system::error_code shutdownEc;
                socket.shutdown(tcp::socket::shutdown_both, shutdownEc);
                socket.close(shutdownEc);
        }
        catch (const exception &e)
        {
                cerr << "TCP message processing failed: " << e.what() << endl;
                if (pSLAM)
                {
                        try
                        {
                                pSLAM->Shutdown();
                        }
                        catch (...)
                        {
                        }
                }
                return 1;
        }

        if (pSLAM)
        {
                pSLAM->Shutdown();

                if (!vTimesTrack.empty())
                {
                        sort(vTimesTrack.begin(), vTimesTrack.end());
                        const float totaltime = accumulate(vTimesTrack.begin(), vTimesTrack.end(), 0.0f);
                        cout << "-------" << endl;
                        cout << "Frames processed: " << vTimesTrack.size() << endl;
                        cout << "median tracking time: " << vTimesTrack[vTimesTrack.size() / 2] << endl;
                        cout << "mean tracking time: " << totaltime / vTimesTrack.size() << endl;
                }
                else
                {
                        cout << "No frames processed." << endl;
                }

                pSLAM->SaveKeyFrameTrajectoryTUM("KeyFrameTrajectory.txt");
        }

        if (!tempSettingsPath.empty())
        {
                std::error_code removeEc;
                filesystem::remove(tempSettingsPath, removeEc);
                if (removeEc)
                {
                        cerr << "Warning: failed to remove temporary settings file: " << removeEc.message() << endl;
                }
        }

        return 0;
}
