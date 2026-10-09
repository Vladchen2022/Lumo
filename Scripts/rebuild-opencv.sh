#!/bin/bash
set -euo pipefail
# Optional source rebuild of the bundled arm64 static libraries. Needs git and CMake.
LUMO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUMO_DEPS="$LUMO_ROOT/.build/opencv-source"
mkdir -p "$LUMO_DEPS"
if [ ! -d "$LUMO_DEPS/opencv/.git" ]; then
    git clone --filter=blob:none https://github.com/opencv/opencv.git "$LUMO_DEPS/opencv"
fi
if [ ! -d "$LUMO_DEPS/opencv_contrib/.git" ]; then
    git clone --filter=blob:none https://github.com/opencv/opencv_contrib.git "$LUMO_DEPS/opencv_contrib"
fi
git -C "$LUMO_DEPS/opencv" checkout --detach c7732e1043c422cda5c243f3a668a3e868602ee1
git -C "$LUMO_DEPS/opencv_contrib" checkout --detach 3544a757871816adda47b2d8a7c2345f8ea5277d
cmake -S "$LUMO_DEPS/opencv" -B "$LUMO_DEPS/build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_INSTALL_PREFIX="$LUMO_DEPS/install" -DBUILD_LIST=core,imgproc -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_opencv_apps=OFF \
    -DWITH_OPENCL=OFF -DWITH_LAPACK=OFF -DWITH_ITT=OFF -DWITH_KLEIDICV=OFF -DWITH_IPP=OFF \
    -DWITH_EIGEN=OFF -DWITH_CAROTENE=OFF -DWITH_OPENEXR=OFF -DBUILD_JAVA=OFF -DBUILD_opencv_python3=OFF
cmake --build "$LUMO_DEPS/build" --parallel 10
cmake --install "$LUMO_DEPS/build"
mkdir -p "$LUMO_ROOT/Vendor/OpenCV/lib" "$LUMO_ROOT/Vendor/OpenCV/include/opencv2/ximgproc"
cp "$LUMO_DEPS/install/lib/libopencv_core.a" "$LUMO_DEPS/install/lib/libopencv_imgproc.a" "$LUMO_ROOT/Vendor/OpenCV/lib/"
ditto "$LUMO_DEPS/install/include/opencv4/opencv2" "$LUMO_ROOT/Vendor/OpenCV/include/opencv2"
cp "$LUMO_DEPS/opencv_contrib/modules/ximgproc/include/opencv2/ximgproc/edge_drawing.hpp" "$LUMO_ROOT/Vendor/OpenCV/include/opencv2/ximgproc/"
for LUMO_FILE in edge_drawing.cpp edge_drawing_common.hpp thinning.cpp; do
    cp "$LUMO_DEPS/opencv_contrib/modules/ximgproc/src/$LUMO_FILE" "$LUMO_ROOT/Sources/CLineTop/OpenCV/"
done
shasum -a 256 "$LUMO_ROOT/Vendor/OpenCV/lib/"*.a
