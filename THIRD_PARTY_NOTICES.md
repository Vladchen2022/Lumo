# Third-party components

Lumo's application code is MIT licensed. Bundled third-party components retain their original licenses.

## LineTop adaptation

`Sources/CLineTop/LineTopBridge.cpp` adapts the thin-line algorithm from the author's LineTop application, supplied for reuse in Lumo. It preserves the photo/illustration preprocessing, EdgeDrawing thresholds, Zhang–Suen thinning, component removal, alpha values and thickness dilation. Component filtering uses a single label pass with identical keep/remove criteria. Lumo uses sRGB-managed input and its existing Metal compositing/output pipeline.

## OpenCV

- OpenCV 4.14.0-pre, commit `c7732e1043c422cda5c243f3a668a3e868602ee1`, from https://github.com/opencv/opencv
- OpenCV contrib, commit `3544a757871816adda47b2d8a7c2345f8ea5277d`, from https://github.com/opencv/opencv_contrib
- Apache License 2.0; applicable retained BSD and SoftFloat/fdlibm notices are in `Vendor/OpenCV/licenses/` and included in the App bundle.

`Vendor/OpenCV/lib/` contains static arm64 core/imgproc libraries rebuilt for macOS 14. Headers are installed public core/imgproc headers plus `ximgproc/edge_drawing.hpp`. `Sources/CLineTop/OpenCV/` contains unmodified `edge_drawing.cpp`, `edge_drawing_common.hpp`, and `thinning.cpp`; its replacement `precomp.hpp` supplies only the public dependencies needed by those files. No OpenCV binaries from LineTop requiring macOS 26 are used.

The regular build uses these checked-in libraries and needs no LineTop installation, Homebrew or Python runtime. To rebuild the libraries from pinned upstream sources with CMake and Xcode command-line tools, run `bash Scripts/rebuild-opencv.sh`. Build configuration disables OpenCL, LAPACK, IPP, ITT, KleidiCV, Eigen, Carotene, Java and Python bindings. System zlib and Accelerate are linked by the package. Library hashes are recorded in `Vendor/OpenCV/SHA256SUMS`.
