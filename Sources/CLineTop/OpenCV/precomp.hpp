// Minimal public-header preamble for the two unmodified OpenCV contrib sources.
#pragma once
#include <opencv2/core.hpp>
#include <opencv2/core/utility.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/ximgproc/edge_drawing.hpp>
#include <algorithm>
#include <map>
namespace cv { namespace ximgproc {
enum ThinningTypes { THINNING_ZHANGSUEN = 0, THINNING_GUOHALL = 1 };
void thinning(InputArray src, OutputArray dst, int thinningType = THINNING_ZHANGSUEN);
}}
