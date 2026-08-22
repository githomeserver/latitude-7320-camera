// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * Does setSharpness() actually keep more detail?
 *
 * setSharpness(0) writes one cell-mean green to both green slots of the output
 * quad; setSharpness(1) gives each slot its own 2x2 quadrant mean. This feeds
 * both a synthetic RGB-IR frame carrying a horizontal grating of known period
 * and amplitude, pulls the green samples back out of each Bayer result, and
 * reports the surviving modulation. A claim of "sharper" that is not measured
 * is just a claim.
 *
 * Only green is expected to move: sharpness does not touch chroma, and the
 * grating is written into green alone so nothing else can account for a change.
 *
 * Build:  g++ -O2 -o /tmp/test-sharp test-sharp.cpp rgbir_to_bayer.cpp
 */

#include "rgbir_to_bayer.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

using namespace libcamera;

namespace {

/* G I G I / R G B G / G I G I / B G R G - the pattern Intel declares. */
const RgbIrToBayer::Channel kPattern[16] = {
	RgbIrToBayer::Green,    RgbIrToBayer::Infrared, RgbIrToBayer::Green,    RgbIrToBayer::Infrared,
	RgbIrToBayer::Red,      RgbIrToBayer::Green,    RgbIrToBayer::Blue,     RgbIrToBayer::Green,
	RgbIrToBayer::Green,    RgbIrToBayer::Infrared, RgbIrToBayer::Green,    RgbIrToBayer::Infrared,
	RgbIrToBayer::Blue,     RgbIrToBayer::Green,    RgbIrToBayer::Red,      RgbIrToBayer::Green,
};

constexpr unsigned int kW = 256;
constexpr unsigned int kH = 256;
constexpr uint16_t kBlack = 0;

/* Scene luma: a horizontal grating of the given period, in source pixels. */
double scene(unsigned int y, double periodSrc)
{
	return 512.0 + 300.0 * std::sin(2.0 * M_PI * y / periodSrc);
}

std::vector<uint8_t> makeFrame(double periodSrc)
{
	std::vector<uint8_t> buf(kW * kH * 2);
	for (unsigned int y = 0; y < kH; y++) {
		for (unsigned int x = 0; x < kW; x++) {
			const RgbIrToBayer::Channel c = kPattern[(y % 4) * 4 + (x % 4)];
			double v = scene(y, periodSrc);
			/* Chroma and IR flat, so only green carries the grating. */
			if (c != RgbIrToBayer::Green)
				v = 512.0;
			const uint16_t s = static_cast<uint16_t>(v);
			buf[(y * kW + x) * 2 + 0] = s & 0xff;
			buf[(y * kW + x) * 2 + 1] = s >> 8;
		}
	}
	return buf;
}

/*
 * Peak-to-peak of the green samples, averaged over columns. In a GRBG output
 * green sits at (even,even) and (odd,odd); both are sampled.
 */
double greenModulation(const std::vector<uint16_t> &out, unsigned int w, unsigned int h)
{
	std::vector<double> rowMean(h, 0.0);
	for (unsigned int y = 0; y < h; y++) {
		double acc = 0.0;
		unsigned int n = 0;
		for (unsigned int x = 0; x < w; x++) {
			const bool isGreen = ((y & 1) == 0 && (x & 1) == 0) ||
					     ((y & 1) == 1 && (x & 1) == 1);
			if (!isGreen)
				continue;
			acc += out[y * w + x];
			n++;
		}
		rowMean[y] = n ? acc / n : 0.0;
	}
	/* Ignore the first and last rows: no edge handling is under test. */
	double lo = 1e9, hi = -1e9;
	for (unsigned int y = 2; y + 2 < h; y++) {
		if (rowMean[y] < lo) lo = rowMean[y];
		if (rowMean[y] > hi) hi = rowMean[y];
	}
	return hi - lo;
}

} /* namespace */

int main()
{
	/*
	 * Two converters rather than one re-tuned between calls, so neither
	 * result can depend on the order they ran in.
	 */
	RgbIrToBayer flat(kPattern, kBlack, 10);
	RgbIrToBayer sharp(kPattern, kBlack, 10);
	flat.setIrSubtract(0.0f);
	sharp.setIrSubtract(0.0f);
	flat.setSharpness(0.0f);   /* cell mean, one value to both green slots */
	sharp.setSharpness(1.0f);  /* per-quadrant mean */

	const unsigned int ow = kW / 2, oh = kH / 2;
	const unsigned int ostride = ow * 2;

	printf("  grating   sharpness 0   sharpness 1   gain\n");
	printf("  (src px)  p-p green     p-p green\n");

	bool improved = true, regressed = false;
	for (double period : { 32.0, 16.0, 8.0, 4.0 }) {
		std::vector<uint8_t> src = makeFrame(period);
		std::vector<uint16_t> a(ow * oh, 0), b(ow * oh, 0);

		if (flat.convertSharp(src.data(), kW, kH, kW * 2, a.data(), ostride,
				      RgbIrToBayer::Order::GRBG) != 0) {
			printf("  conversion at sharpness 0 failed\n");
			return 1;
		}
		if (sharp.convertSharp(src.data(), kW, kH, kW * 2, b.data(), ostride,
				       RgbIrToBayer::Order::GRBG) != 0) {
			printf("  conversion at sharpness 1 failed\n");
			return 1;
		}

		const double ma = greenModulation(a, ow, oh);
		const double mb = greenModulation(b, ow, oh);
		const double gain = ma > 0.5 ? mb / ma : (mb > 0.5 ? 999.0 : 1.0);
		printf("  %6.0f    %10.1f    %10.1f    %5.2fx\n", period, ma, mb, gain);

		if (mb < ma - 0.5)
			regressed = true;
		if (period <= 16.0 && mb <= ma + 0.5)
			improved = false;
	}

	printf("\n");
	if (regressed) {
		printf("  FAIL: sharpness 1 lost detail somewhere\n");
		return 1;
	}
	if (!improved) {
		printf("  FAIL: sharpness 1 gained nothing at the frequencies that matter\n");
		return 1;
	}
	printf("  PASS: sharpness 1 preserves strictly more green detail than 0\n");
	return 0;
}
