cmake_minimum_required(VERSION 3.10)
project(orbslam3_mono_networked LANGUAGES CXX)

# Allow override of ORB_SLAM3 location if already cloned externally
set(ORB_SLAM3_ROOT "${CMAKE_SOURCE_DIR}/ORB_SLAM3" CACHE PATH "Path to ORB_SLAM3 root containing include/ and lib/")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Prefer Release unless user sets CMAKE_BUILD_TYPE
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# Dependencies: OpenCV, Pangolin, Eigen
find_package(OpenCV REQUIRED)
find_package(Pangolin REQUIRED)
find_package(Eigen3 REQUIRED)

# Include paths
include_directories(
  ${OpenCV_INCLUDE_DIRS}
  ${Pangolin_INCLUDE_DIRS}
  ${EIGEN3_INCLUDE_DIR}
  ${ORB_SLAM3_ROOT}/include
  ${ORB_SLAM3_ROOT}/Thirdparty/DBoW2/DBoW2
  ${ORB_SLAM3_ROOT}/Thirdparty/g2o
  ${ORB_SLAM3_ROOT}/Thirdparty/Sophus
)

# Library paths (if ORB_SLAM3 build.sh was executed)
link_directories(
  ${ORB_SLAM3_ROOT}/lib
  ${ORB_SLAM3_ROOT}/Thirdparty/DBoW2/lib
  ${ORB_SLAM3_ROOT}/Thirdparty/g2o/lib
)

# Source file (copy or symlink orbslam3_mono_networked.cc into this directory or point to original)
set(NETWORKED_SRC ${CMAKE_SOURCE_DIR}/orbslam3_mono_networked.cc)
if(NOT EXISTS ${NETWORKED_SRC})
  message(FATAL_ERROR "orbslam3_mono_networked.cc not found at ${NETWORKED_SRC}")
endif()

add_executable(orbslam3_mono_networked ${NETWORKED_SRC})

# Link libraries; names may differ based on ORB_SLAM3 fork (DBoW2 vs DBoW2, g2o components). Adjust if needed.
# Basic set:
#  - ORB_SLAM3 main library
#  - DBoW2 vocabulary lib
#  - g2o core libs (some forks build monolithic g2o)
# Pangolin + OpenCV + system libs.

# Attempt to link common g2o component libs if present
foreach(g2o_lib g2o_core g2o_stuff g2o_types_sba g2o_types_sim3 g2o_solver_csparse g2o_solver_dense g2o_solver_pcg g2o_types_slam3d g2o_types_slam2d)
  find_library(${g2o_lib}_PATH NAMES ${g2o_lib} PATHS ${ORB_SLAM3_ROOT}/Thirdparty/g2o/lib NO_DEFAULT_PATH)
  if(${g2o_lib}_PATH)
    list(APPEND G2O_FOUND_LIBS ${${g2o_lib}_PATH})
  endif()
endforeach()

# Fallback: link just g2o
find_library(G2O_LIB NAMES g2o PATHS ${ORB_SLAM3_ROOT}/Thirdparty/g2o/lib NO_DEFAULT_PATH)
if(G2O_LIB AND NOT G2O_FOUND_LIBS)
  set(G2O_FOUND_LIBS ${G2O_LIB})
endif()

# DBoW2
find_library(DBOW2_LIB NAMES DBoW2 PATHS ${ORB_SLAM3_ROOT}/Thirdparty/DBoW2/lib NO_DEFAULT_PATH)

# ORB_SLAM3
find_library(ORB_SLAM3_LIB NAMES ORB_SLAM3 PATHS ${ORB_SLAM3_ROOT}/lib NO_DEFAULT_PATH)

# Compose link list
set(LINK_LIBS
  ${ORB_SLAM3_LIB}
  ${DBOW2_LIB}
  ${G2O_FOUND_LIBS}
  ${Pangolin_LIBRARIES}
  ${OpenCV_LIBS}
  pthread boost_system ssl crypto
)

# Filter out any NOTFOUND entries
list(FILTER LINK_LIBS EXCLUDE REGEX "NOTFOUND")

if(NOT ORB_SLAM3_LIB)
  message(WARNING "ORB_SLAM3 library not found; build may fail. Did you run build.sh in ORB_SLAM3?")
endif()

if(NOT DBOW2_LIB)
  message(WARNING "DBoW2 library not found; build may fail.")
endif()

if(NOT G2O_FOUND_LIBS)
  message(WARNING "No g2o component libraries detected; relying on possible monolithic g2o or transitive linkage.")
endif()

message(STATUS "Linking with libs: ${LINK_LIBS}")

target_link_libraries(orbslam3_mono_networked PRIVATE ${LINK_LIBS})

target_compile_definitions(orbslam3_mono_networked PRIVATE EIGEN_NO_DEBUG)

# Suggest run command
add_custom_target(run_networked
  COMMAND orbslam3_mono_networked
  DEPENDS orbslam3_mono_networked
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "Run orbslam3_mono_networked executable"
)
