/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Verify RgbIrToBayer against the Python reference in tools/rgbir-pipeline.py,
 * using a real captured frame. Run via check.sh.
 *
 *   ./test_rgbir <raw> <width> <height> <stride> <blacklevel> <out.bayer>
 *
 * Prints per-channel means so the C++ and Python can be compared numerically
 * rather than by eye.
 */

#include "rgbir_to_bayer.h"

#include <stdio.h>
#include <stdlib.h>
#include <vector>

using namespace libcamera;

int main(int argc, char **argv)
{
	if (argc < 7) {
		fprintf(stderr, "usage: %s raw w h stride black out\n", argv[0]);
		return 1;
	}
	const char *rawPath = argv[1];
	unsigned int w = atoi(argv[2]), h = atoi(argv[3]), stride = atoi(argv[4]);
	uint16_t black = atoi(argv[5]);
	const char *outPath = argv[6];

	FILE *f = fopen(rawPath, "rb");
	if (!f) {
		perror("open raw");
		return 1;
	}
	std::vector<uint8_t> src(static_cast<size_t>(stride) * h);
	if (fread(src.data(), 1, src.size(), f) != src.size()) {
		fprintf(stderr, "short read\n");
		fclose(f);
		return 1;
	}
	fclose(f);

	/* G I G I / R G B G / G I G I / B G R G */
	using C = RgbIrToBayer::Channel;
	const C pattern[16] = {
		C::Green, C::Infrared, C::Green, C::Infrared,
		C::Red,   C::Green,    C::Blue,  C::Green,
		C::Green, C::Infrared, C::Green, C::Infrared,
		C::Blue,  C::Green,    C::Red,   C::Green,
	};

	RgbIrToBayer conv(pattern, black, 10);

	const unsigned int ow = w / 2, oh = h / 2;
	const unsigned int ostride = ow * 2;
	std::vector<uint16_t> dst(static_cast<size_t>(ow) * oh);

	int ret = conv.convert(src.data(), w, h, stride,
			       dst.data(), ostride, nullptr);
	if (ret) {
		fprintf(stderr, "convert failed: %d\n", ret);
		return 1;
	}

	/* GRBG output: G R / B G */
	double sg = 0, sr = 0, sb = 0;
	size_t ng = 0, nr = 0, nb = 0;
	for (unsigned int y = 0; y < oh; y++) {
		for (unsigned int x = 0; x < ow; x++) {
			double v = static_cast<double>(dst[y * ow + x]) - black;
			if ((y % 2) == 0)
				(x % 2) == 0 ? (sg += v, ng++) : (sr += v, nr++);
			else
				(x % 2) == 0 ? (sb += v, nb++) : (sg += v, ng++);
		}
	}
	printf("cpp  %ux%u -> %ux%u\n", w, h, ow, oh);
	printf("cpp  G %.3f  R %.3f  B %.3f\n", sg / ng, sr / nr, sb / nb);

	f = fopen(outPath, "wb");
	if (!f) {
		perror("open out");
		return 1;
	}
	fwrite(dst.data(), 2, dst.size(), f);
	fclose(f);
	return 0;
}
