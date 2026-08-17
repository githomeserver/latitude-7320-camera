// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * Measure the temporal denoise on a real captured sequence.
 *
 * Two things have to be true for this to be worth shipping: it must actually
 * lower the noise floor on still content, and it must not smear moving content.
 * A denoiser that only does the first is a blur.
 *
 * Capture with:
 *   cam -c1 -s role=raw -C120 --file='raw#.bin'
 *
 * Build: g++ -O2 -o test-denoise test-denoise.cpp rgbir_to_bayer.cpp temporal_denoise.cpp
 * Run:   ./test-denoise <dir-with-raw-frames>
 */

#include "rgbir_to_bayer.h"
#include "temporal_denoise.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <string>
#include <vector>

using namespace libcamera;

namespace {

const RgbIrToBayer::Channel kPattern[16] = {
	RgbIrToBayer::Green,    RgbIrToBayer::Infrared, RgbIrToBayer::Green,    RgbIrToBayer::Infrared,
	RgbIrToBayer::Red,      RgbIrToBayer::Green,    RgbIrToBayer::Blue,     RgbIrToBayer::Green,
	RgbIrToBayer::Green,    RgbIrToBayer::Infrared, RgbIrToBayer::Green,    RgbIrToBayer::Infrared,
	RgbIrToBayer::Blue,     RgbIrToBayer::Green,    RgbIrToBayer::Red,      RgbIrToBayer::Green,
};

constexpr unsigned int W = 2592, H = 1944;
constexpr unsigned int OW = W / 2, OH = H / 2;

std::vector<std::string> frameList(const char *dir)
{
	std::vector<std::string> v;
	DIR *d = opendir(dir);
	if (!d)
		return v;
	while (struct dirent *e = readdir(d))
		if (strncmp(e->d_name, "rawcam0-stream0-", 16) == 0)
			v.push_back(std::string(dir) + "/" + e->d_name);
	closedir(d);
	std::sort(v.begin(), v.end());
	return v;
}

bool readFrame(const std::string &p, std::vector<uint8_t> &buf)
{
	FILE *f = fopen(p.c_str(), "rb");
	if (!f)
		return false;
	bool ok = fread(buf.data(), 1, buf.size(), f) == buf.size();
	fclose(f);
	return ok;
}

/* Green lattice of a GBRG/GRBG output: the (even,even) samples. */
std::vector<double> greenLattice(const std::vector<uint16_t> &b)
{
	std::vector<double> g((OW / 2) * (OH / 2));
	for (unsigned int y = 0; y < OH / 2; y++)
		for (unsigned int x = 0; x < OW / 2; x++)
			g[y * (OW / 2) + x] = b[(y * 2) * OW + (x * 2)];
	return g;
}

double flatBlockNoise(const std::vector<double> &g)
{
	const unsigned int gw = OW / 2, gh = OH / 2, B = 16;
	std::vector<double> sds;
	for (unsigned int by = 0; by + B <= gh; by += B)
		for (unsigned int bx = 0; bx + B <= gw; bx += B) {
			double m = 0.0;
			for (unsigned int y = 0; y < B; y++)
				for (unsigned int x = 0; x < B; x++)
					m += g[(by + y) * gw + bx + x];
			m /= B * B;
			double v = 0.0;
			for (unsigned int y = 0; y < B; y++)
				for (unsigned int x = 0; x < B; x++) {
					double d = g[(by + y) * gw + bx + x] - m;
					v += d * d;
				}
			sds.push_back(std::sqrt(v / (B * B)));
		}
	if (sds.empty())
		return 0.0;
	std::sort(sds.begin(), sds.end());
	return sds[sds.size() / 10];
}

double meanAbsDiff(const std::vector<uint16_t> &a, const std::vector<uint16_t> &b)
{
	double t = 0.0;
	for (size_t i = 0; i < a.size(); i++)
		t += std::fabs((double)a[i] - (double)b[i]);
	return a.empty() ? 0.0 : t / a.size();
}

} /* namespace */

int main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : ".";
	std::vector<std::string> frames = frameList(dir);
	if (frames.size() < 20) {
		fprintf(stderr, "need at least 20 raw frames in %s, found %zu\n", dir, frames.size());
		return 2;
	}
	const float alpha = argc > 2 ? atof(argv[2]) : 0.25f;
	const int thr = argc > 3 ? atoi(argv[3]) : 40;

	RgbIrToBayer conv(kPattern, 64, 10);
	conv.setIrSubtract(1.0f);
	conv.setSharpness(0.5f);

	std::vector<uint8_t> src((size_t)W * H * 2);
	std::vector<uint16_t> bayer(OW * OH), clean(OW * OH);

	TemporalDenoise dn;
	dn.configure(alpha, thr);

	printf("  %zu frames, alpha=%.2f threshold=%d\n\n", frames.size(), alpha, thr);
	printf("  frame   noise(raw)   noise(denoised)   reduction   moving%%\n");

	double firstRaw = 0.0, lastRaw = 0.0, lastClean = 0.0;
	const unsigned int nStill = std::min<size_t>(frames.size(), 60);
	for (unsigned int i = 0; i < nStill; i++) {
		if (!readFrame(frames[i], src)) {
			fprintf(stderr, "read failed: %s\n", frames[i].c_str());
			return 1;
		}
		conv.convertSharp(src.data(), W, H, W * 2, bayer.data(), OW * 2,
				  RgbIrToBayer::Order::GBRG);
		clean = bayer;
		dn.apply(clean.data(), clean.size());

		if (i == 0 || i == 4 || i == 9 || i == 19 || i == 39 || i == nStill - 1) {
			const double nr = flatBlockNoise(greenLattice(bayer));
			const double nc = flatBlockNoise(greenLattice(clean));
			printf("  %5u   %9.3f   %13.3f   %8.2fx   %6.1f\n",
			       i, nr, nc, nc > 0 ? nr / nc : 0, dn.lastMotionFraction() * 100.0);
			if (i == 0)
				firstRaw = nr;
			lastRaw = nr;
			lastClean = nc;
		}
	}
	(void)firstRaw;

	/*
	 * Temporal noise: how much one sample varies frame to frame once the
	 * recursion has settled. This is the honest measure. The spatial
	 * flat-block figure above cannot fall below the scene texture inside
	 * those blocks, so it saturates and understates the improvement as the
	 * noise approaches it.
	 */
	{
		const unsigned int nT = 24;
		const size_t stride = 997;              /* prime: spreads samples out */
		std::vector<double> sumR, sumR2, sumC, sumC2;
		std::vector<uint16_t> b2(OW * OH);
		TemporalDenoise dn2;
		dn2.configure(alpha, thr);
		unsigned int n = 0;
		for (unsigned int i = 0; i < nStill && n < nT + 8; i++) {
			if (!readFrame(frames[i], src)) break;
			conv.convertSharp(src.data(), W, H, W * 2, b2.data(), OW * 2,
					  RgbIrToBayer::Order::GBRG);
			std::vector<uint16_t> c2 = b2;
			dn2.apply(c2.data(), c2.size());
			if (i < 8) continue;               /* let the recursion settle */
			if (sumR.empty()) {
				const size_t m = b2.size() / stride;
				sumR.assign(m, 0.0); sumR2.assign(m, 0.0);
				sumC.assign(m, 0.0); sumC2.assign(m, 0.0);
			}
			for (size_t k = 0; k < sumR.size(); k++) {
				const double vr = b2[k * stride], vc = c2[k * stride];
				sumR[k] += vr; sumR2[k] += vr * vr;
				sumC[k] += vc; sumC2[k] += vc * vc;
			}
			n++;
		}
		double tr = 0.0, tc = 0.0;
		for (size_t k = 0; k < sumR.size(); k++) {
			const double mr = sumR[k] / n, mc = sumC[k] / n;
			double vr = sumR2[k] / n - mr * mr, vc = sumC2[k] / n - mc * mc;
			tr += std::sqrt(vr > 0 ? vr : 0);
			tc += std::sqrt(vc > 0 ? vc : 0);
		}
		tr /= sumR.size(); tc /= sumC.size();
		printf("\n  temporal noise over %u settled frames, %zu samples:\n", n, sumR.size());
		printf("  raw %.3f -> denoised %.3f  (%.2fx cleaner)\n", tr, tc, tc > 0 ? tr / tc : 0);
	}

	/*
	 * Motion response. Feed a frame shifted by 8 samples, which no amount of
	 * sensor noise resembles, and see how fast the output becomes the new
	 * content. A denoiser that needs many frames to catch up is smearing.
	 */
	printf("\n  motion response (content jumps at step 0):\n");
	printf("  step   |output - truth|   moving%%\n");
	if (!readFrame(frames[nStill], src))
		return 1;
	conv.convertSharp(src.data(), W, H, W * 2, bayer.data(), OW * 2,
			  RgbIrToBayer::Order::GBRG);
	std::vector<uint16_t> shifted(OW * OH, 0);
	for (unsigned int y = 0; y < OH; y++)
		for (unsigned int x = 0; x + 8 < OW; x++)
			shifted[y * OW + x] = bayer[y * OW + x + 8];

	for (int step = 0; step < 6; step++) {
		clean = shifted;
		dn.apply(clean.data(), clean.size());
		printf("  %4d   %15.3f   %6.1f\n", step, meanAbsDiff(clean, shifted),
		       dn.lastMotionFraction() * 100.0);
	}

	printf("\n  still-scene noise %.3f -> %.3f (%.2fx cleaner)\n",
	       lastRaw, lastClean, lastClean > 0 ? lastRaw / lastClean : 0);
	return 0;
}
