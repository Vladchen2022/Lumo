// Adapted from the user's LineTop/OpenCVLineProcessor.mm thin-line path.
#include "LineTopBridge.h"
#include "OpenCV/precomp.hpp"
#include <cmath>
#include <cstring>

bool LumoExtractLineMask(const uint8_t *rgba, size_t width, size_t height,
                         bool photoLike, double edgeStrength, double contrast,
                         double brightness, double thickness, uint8_t *output) {
    if (!rgba || !output || width < 3 || height < 3 || width > 4096 || height > 4096) return false;
    try {
        cv::Mat source((int)height, (int)width, CV_8UC4, const_cast<uint8_t *>(rgba));
        cv::Mat gray, prepared, smoothed;
        cv::cvtColor(source, gray, cv::COLOR_RGBA2GRAY);
        gray.convertTo(prepared, -1, std::clamp(1.05 + contrast * .22, .9, 1.7), std::clamp(brightness * 38.0, -18.0, 18.0));
        if (photoLike) cv::bilateralFilter(prepared, smoothed, 7, 30, 30);
        else cv::GaussianBlur(prepared, smoothed, cv::Size(3, 3), .6);
        auto drawing = cv::ximgproc::createEdgeDrawing();
        auto params = drawing->params;
        params.EdgeDetectionOperator = cv::ximgproc::EdgeDrawing::SOBEL;
        params.GradientThresholdValue = photoLike
            ? (int)std::lround(std::clamp(34.0 + edgeStrength * 4.0, 28.0, 44.0))
            : (int)std::lround(std::clamp(24.0 + edgeStrength * 3.0, 18.0, 34.0));
        params.AnchorThresholdValue = 0; params.ScanInterval = 1;
        params.MinPathLength = photoLike ? 18 : 12;
        params.Sigma = photoLike ? 1.2f : .8f; params.NFAValidation = false;
        drawing->setParams(params); drawing->detectEdges(smoothed);
        cv::Mat edges, thinned;
        drawing->getEdgeImage(edges);
        cv::threshold(edges, edges, 0, 255, cv::THRESH_BINARY);
        cv::ximgproc::thinning(edges, thinned);
        cv::Mat labels, stats, centroids;
        const int count = cv::connectedComponentsWithStats(thinned, labels, stats, centroids, 8, CV_32S);
        // Same component rules as LineTop; one pass avoids scanning the entire
        // canvas once for each small component in a textured photograph.
        std::vector<uint8_t> keep(count, 0);
        for (int i = 1; i < count; ++i) {
            const int area = stats.at<int>(i, cv::CC_STAT_AREA);
            const int side = std::max(stats.at<int>(i, cv::CC_STAT_WIDTH), stats.at<int>(i, cv::CC_STAT_HEIGHT));
            keep[i] = !(area < (photoLike ? 14 : 8) && side < (photoLike ? 18 : 12));
        }
        for (int y = 0; y < thinned.rows; ++y) {
            auto row = thinned.ptr<uint8_t>(y); auto label = labels.ptr<int>(y);
            for (int x = 0; x < thinned.cols; ++x) if (!keep[label[x]]) row[x] = 0;
        }
        if (photoLike) {cv::Mat refined; cv::ximgproc::thinning(thinned, refined); thinned = refined;}
        cv::Mat mask;
        thinned.convertTo(mask, CV_8UC1, (photoLike ? 176.0 : 210.0) / 255.0);
        const int radius = std::max(0, (int)std::lround(thickness * .35));
        if (radius > 0) cv::dilate(mask, mask, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(radius * 2 + 1, radius * 2 + 1)));
        for (size_t y = 0; y < height; ++y) std::memcpy(output + y * width, mask.ptr((int)y), width);
        return true;
    } catch (...) {return false;}
}
