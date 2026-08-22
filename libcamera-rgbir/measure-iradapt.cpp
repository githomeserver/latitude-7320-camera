// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * What does adaptive IR subtraction buy on a REAL photon-starved frame?
 *
 * The unit test checks the shrinkage against its own algebra. This checks it
 * against a sensor: it runs one raw frame through convertSharp() with the
 * coefficient fixed and then adaptive, and reports the grain in flat areas of
 * the resulting Bayer.
 *
 * The starved frame the rule is for cannot be captured on demand in a lit room,
 * so make one: force a short exposure at the sensor while capturing raw.
 *
 *   v4l2-ctl -d /dev/v4l-subdev8 -c exposure=120   (in a loop, while cam runs)
 *
 * Build:  g++ -O2 -o /tmp/measure-iradapt measure-iradapt.cpp rgbir_to_bayer.cpp
 * Run:    /tmp/measure-iradapt raw.bin [width height blacklevel k]
 */

#include "rgbir_to_bayer.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

using namespace libcamera;

namespace {

const RgbIrToBayer::Channel kPattern[16] = {
	RgbIrToBayer::Green,    RgbIrToBayer::Infrared, RgbIrToBayer::Green,    RgbIrToBayer::Infrared,
	RgbIrToBayer::Red,      RgbIrToBayer::Green,    RgbIrToBayer::Blue,     RgbIrToBayer::Green,
	RgbIrToBayer::Green,    RgbIrToBayer::Infrared, RgbIrToBayer::Green,    RgbIrToBayer::Infrared,
	RgbIrToBayer::Blue,     RgbIrToBayer::Green,    RgbIrToBayer::Red,      RgbIrToBayer::Green,
};

double sd(const std::vector<double> &v)
{
	double m = 0;
	for (double x : v) m += x;
	m /= v.size();
	double s = 0;
	for (double x : v) s += (x - m) * (x - m);
	return std::sqrt(s / v.size());
}

/*
 * Grain in the green plane of the output Bayer, as the 25th percentile of the
 * local standard deviation over 16x16 green windows. A low percentile because
 * the frame contains edges and those are not grain; the same statistic the
 * live-pipeline measurements used, so the numbers are comparable.
 */
struct Stats { double grain, meanG, meanR, meanB; };

Stats measure(const std::vector<uint16_t> &bayer, unsigned int w, unsigned int h)
{
	std::vector<double> blocks;
	double sg = 0, sr = 0, sb = 0;
	size_t ng = 0, nr = 0, nb = 0;

	for (unsigned int y = 0; y + 1 < h; y += 2) {
		for (unsigned int x = 0; x + 1 < w; x += 2) {
			sg += bayer[(size_t)y * w + x];       ng++;   /* G */
			sr += bayer[(size_t)y * w + x + 1];   nr++;   /* R in GRBG */
			sb += bayer[(size_t)(y + 1) * w + x]; nb++;   /* B */
		}
	}

	for (unsigned int y0 = 0; y0 + 32 < h; y0 += 32) {
		for (unsigned int x0 = 0; x0 + 32 < w; x0 += 32) {
			std::vector<double> v;
			for (unsigned int dy = 0; dy < 32; dy += 2)
				for (unsigned int dx = 0; dx < 32; dx += 2)
					v.push_back(bayer[(size_t)(y0 + dy) * w + x0 + dx]);
			double m = 0;
			for (double a : v) m += a;
			if (m / v.size() < 4.0)
				continue;			/* black, not flat */
			blocks.push_back(sd(v));
		}
	}
	std::sort(blocks.begin(), blocks.end());
	return { blocks.empty() ? 0.0 : blocks[blocks.size() / 4],
		 sg / ng, sr / nr, sb / nb };
}

} /* namespace */

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s raw.bin [w h black k]\n", argv[0]);
		return 2;
	}
	const unsigned int W = argc > 2 ? atoi(argv[2]) : 2592;
	const unsigned int H = argc > 3 ? atoi(argv[3]) : 1944;
	const uint16_t black = argc > 4 ? atoi(argv[4]) : 64;
	const float k = argc > 5 ? atof(argv[5]) : 2.0f;

	FILE *f = fopen(argv[1], "rb");
	if (!f) { perror(argv[1]); return 1; }
	std::vector<uint8_t> src((size_t)W * H * 2);
	if (fread(src.data(), 1, src.size(), f) != src.size()) {
		fprintf(stderr, "%s: short read, expected %zu bytes\n", argv[1], src.size());
		return 1;
	}
	fclose(f);

	const unsigned int ow = W / 2, oh = H / 2;
	std::vector<uint16_t> dst((size_t)ow * oh);

	printf("%s  %ux%u  black %u  tuned k %.2f\n\n", argv[1], W, H, black, k);
	printf("  %-22s %8s %8s %8s %8s\n", "", "grain", "mean G", "mean R", "mean B");

	Stats fixed{}, adapt{};
	for (int pass = 0; pass < 2; pass++) {
		RgbIrToBayer conv(kPattern, black, 10);
		conv.setIrSubtract(k);
		conv.setSharpness(0.5f);
		conv.setIrAdaptive(pass == 1);
		/* Twice: the first frame has no noise estimate yet. */
		for (int i = 0; i < 40; i++)
			conv.convertSharp(src.data(), W, H, W * 2, dst.data(),
					  ow * 2, RgbIrToBayer::Order::GRBG);
		Stats s = measure(dst, ow, oh);
		(pass ? adapt : fixed) = s;
		printf("  %-22s %8.3f %8.1f %8.1f %8.1f\n",
		       pass ? "adaptive per cell" : "fixed coefficient",
		       s.grain, s.meanG, s.meanR, s.meanB);

		/*
		 * The coefficient varies per cell, so a single reported number
		 * says little. Print the curve it settled on instead.
		 */
		if (pass) {
			printf("\n  coefficient by cell IR level (black-relative):\n   ");
			for (int ir : { 1, 2, 5, 10, 20, 50, 100, 200 })
				printf(" %d:%.2f", ir, conv.irCoefficientAt(ir));
			printf("\n");
		}
	}

	printf("\n  grain %.2fx better\n", fixed.grain / std::max(adapt.grain, 1e-9));
	printf("  R/G %.4f -> %.4f, B/G %.4f -> %.4f  (saturation retained if these hold)\n",
	       fixed.meanR / fixed.meanG, adapt.meanR / adapt.meanG,
	       fixed.meanB / fixed.meanG, adapt.meanB / adapt.meanG);
	return 0;
}
