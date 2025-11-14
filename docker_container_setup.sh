#!/usr/bin/env bash
set -e  # Exit immediately if a command fails
set -o pipefail

# 1. Install dependencies
echo "=== Installing dependencies ==="
apt-get update
apt-get install -y \
    sudo build-essential python3 python3-venv python3-pip git \
    libopencv-dev libeigen3-dev ninja-build libboost-all-dev libssl-dev \
    libgl1-mesa-dev libwayland-dev libxkbcommon-dev wayland-protocols libegl1-mesa-dev \
    libc++-dev libepoxy-dev libglew-dev libeigen3-dev cmake g++ ninja-build \
    libjpeg-dev libpng-dev catch2 \
    libavcodec-dev libavutil-dev libavformat-dev libswscale-dev libavdevice-dev \
    libdc1394-dev libraw1394-dev libopenni-dev python3-dev wget

# 2. Build Pangolin from source
echo "=== Cloning and building Pangolin ==="
git clone https://github.com/stevenlovegrove/Pangolin.git
cd Pangolin

cmake -B build -GNinja
cmake --build build
sudo cmake --build build -t install

cd ..

# 3. Clone and build ORB_SLAM3
echo "=== Cloning and building ORB_SLAM3 ==="
git clone https://github.com/devansh0703/ORB_SLAM3.git
cd ORB_SLAM3

chmod +x ./build.sh
./build.sh
sudo ldconfig

wget https://raw.githubusercontent.com/SoloFausto/SEND-SLAM/refs/heads/main/slam_backends/orbslam3_mono_networked.cc -O ./orbslam3_mono_networked.cc

g++ -std=c++17 -O3 orbslam3_mono_networked.cc -o orbslam3_mono_networked \
    $(pkg-config --cflags --libs opencv4) \
    -I. -I./include -I/usr/local/include -I/usr/include/eigen3 \
    -I./Thirdparty/Sophus \
    -L./lib -L./Thirdparty/DBoW2/lib -L./Thirdparty/g2o/lib -L/usr/local/lib \
    -lORB_SLAM3 -lDBoW2 -lg2o -lpangolin -pthread -lboost_system -lssl -lcrypto


chmod +x orbslam3_mono_networked



echo "=== Setup complete! ==="
