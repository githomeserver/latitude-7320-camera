// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * Does normalising tile motion by the shading gain keep real motion detectable?
 *
 * Dividing out the gain makes amplified corner NOISE stop reading as motion -
 * that is the point. The risk is that it also makes amplified corner MOTION
 * stop reading as motion, which would smear anything that moves out there.
 * It should not: shading multiplies signal and noise alike, so dividing by the
 * same number leaves their ratio, and the threshold, meaning what it did.
 *
 * This checks both halves on synthetic frames with a known 3.5x corner gain.
 *
 * Build: g++ -O2 -o /tmp/test-denoise-gain test-denoise-gain.cpp temporal_denoise.cpp
 */

#include "temporal_denoise.h"

#include <cmath>
#include <cstdio>
#include <random>
#include <vector>

using namespace libcamera;

namespace {

constexpr unsigned int W = 320, H = 256;
constexpr uint16_t kOne = 1024;
constexpr unsigned int MW = 3, MH = 3;

/* Unity in the centre, 3.5x at every corner - the shape measured on this lens. */
const uint16_t kGain[MW * MH] = {
	3584, 2048, 3584,
	2048, 1024, 2048,
	3584, 2048, 3584,
};

float gainAt(unsigned int x, unsigned int y)
{
	const float u = (float)x / (W - 1) * (MW - 1);
	const float v = (float)y / (H - 1) * (MH - 1);
	const unsigned int x0 = std::min((unsigned int)u, MW - 2);
	const unsigned int y0 = std::min((unsigned int)v, MH - 2);
	const float dx = u - x0, dy = v - y0;
	const float a = kGain[y0 * MW + x0], b = kGain[y0 * MW + x0 + 1];
	const float c = kGain[(y0 + 1) * MW + x0], d = kGain[(y0 + 1) * MW + x0 + 1];
	const float top = a + (b - a) * dx, bot = c + (d - c) * dx;
	return (top + (bot - top) * dy) / kOne;
}

/*
 * A frame as the denoise sees it: base level plus noise, both already
 * multiplied by the shading gain, with an optional bright square that moves.
 */
void makeFrame(std::vector<uint16_t> &f, std::mt19937 &rng, int objX, int objY)
{
	/*
	 * Noise big enough that the CORNER crosses the motion threshold once
	 * the gain is applied, because that is the whole failure mode: 15 * 3.5
	 * is 52 counts against a threshold of 40, so without the correction
	 * every corner tile is classified as moving and never averaged. A
	 * quieter scene stays under the threshold and the bug does not appear.
	 */
	std::normal_distribution<float> n(0.0f, 15.0f);
	for (unsigned int y = 0; y < H; y++) {
		for (unsigned int x = 0; x < W; x++) {
			const float g = gainAt(x, y);
			float v = (200.0f + n(rng)) * g;
			if (objX >= 0 && (int)x >= objX && (int)x < objX + 24 &&
			    (int)y >= objY && (int)y < objY + 24)
				v = (600.0f + n(rng)) * g;
			f[(size_t)y * W + x] = (uint16_t)std::lround(v < 0 ? 0 : v);
		}
	}
}

float meanAt(const std::vector<uint16_t> &f, unsigned int x0, unsigned int y0,
	     unsigned int k = 16)
{
	double s = 0;
	for (unsigned int dy = 0; dy < k; dy++)
		for (unsigned int dx = 0; dx < k; dx++)
			s += f[(size_t)(y0 + dy) * W + x0 + dx];
	return (float)(s / (k * k));
}

int failures = 0;

void check(const char *what, bool ok, const char *detail)
{
	if (!ok)
		failures++;
	printf("  %-52s %s   %s\n", what, ok ? "ok  " : "FAIL", detail);
}

/*
 * Run still frames and return the TEMPORAL noise left in a patch - the sd of
 * each pixel across frames, averaged over the patch.
 *
 * Not the spatial sd of one frame: in the corner that is dominated by the
 * shading ramp running across the patch, which is real signal and which the
 * denoise neither can nor should remove. Measuring it hides the effect
 * entirely - it read 16.97 against 15.89 for a change that is nearly 2x.
 */
float stillNoise(bool withMap, unsigned int px, unsigned int py)
{
	TemporalDenoise dn;
	dn.configure(0.35f, 40);
	dn.setGeometry(W, H);
	if (withMap)
		dn.setGainMap(kGain, MW, MH, kOne, W, H, 0);
	std::mt19937 rng(7);
	std::vector<uint16_t> f((size_t)W * H);
	for (int i = 0; i < 60; i++) {
		makeFrame(f, rng, -1, 0);
		dn.apply(f.data(), f.size());
	}

	constexpr unsigned int k = 16, n = 24;
	std::vector<std::vector<float>> series((size_t)k * k);
	for (unsigned int i = 0; i < n; i++) {
		makeFrame(f, rng, -1, 0);
		dn.apply(f.data(), f.size());
		for (unsigned int dy = 0; dy < k; dy++)
			for (unsigned int dx = 0; dx < k; dx++)
				series[(size_t)dy * k + dx].push_back(
					f[(size_t)(py + dy) * W + px + dx]);
	}
	double total = 0;
	for (const auto &s : series) {
		double m = 0;
		for (float v : s) m += v;
		m /= s.size();
		double q = 0;
		for (float v : s) q += (v - m) * (v - m);
		total += std::sqrt(q / s.size());
	}
	return (float)(total / series.size());
}

} /* namespace */

int main()
{
	printf("shading gain 3.5x at the corners, unity at the centre\n\n");

	const float cornerOff = stillNoise(false, 8, 8);
	const float cornerOn = stillNoise(true, 8, 8);
	const float centreOff = stillNoise(false, W / 2 - 8, H / 2 - 8);
	const float centreOn = stillNoise(true, W / 2 - 8, H / 2 - 8);

	char buf[96];
	snprintf(buf, sizeof(buf), "temporal sd %.2f -> %.2f", cornerOff, cornerOn);
	check("still corner: gain map lets the denoise work there",
	      cornerOn < cornerOff * 0.7f, buf);
	snprintf(buf, sizeof(buf), "temporal sd %.2f -> %.2f", centreOff, centreOn);
	check("still centre: unchanged, gain is unity there",
	      std::fabs(centreOn - centreOff) < 0.35f, buf);

	/*
	 * Now the half that could regress. A square crosses the corner; after it
	 * arrives, the output there must reach the object's brightness rather
	 * than lag behind it as a smear.
	 */
	{
		TemporalDenoise dn;
		dn.configure(0.35f, 40);
		dn.setGeometry(W, H);
		dn.setGainMap(kGain, MW, MH, kOne, W, H, 0);
		std::mt19937 rng(11);
		std::vector<uint16_t> f((size_t)W * H);
		for (int i = 0; i < 40; i++) {
			makeFrame(f, rng, -1, 0);
			dn.apply(f.data(), f.size());
		}
		const float bg = meanAt(f, 16, 16);
		for (int i = 0; i < 6; i++) {
			makeFrame(f, rng, 16, 16);
			dn.apply(f.data(), f.size());
		}
		const float got = meanAt(f, 16, 16);
		const float want = 600.0f * gainAt(24, 24);
		snprintf(buf, sizeof(buf), "bg %.0f -> %.0f, object is %.0f", bg, got, want);
		check("moving object in the corner is not smeared away",
		      got > bg + (want - bg) * 0.85f, buf);
	}

	printf("\n%s\n", failures ? "FAILURES" : "all checks passed");
	return failures ? 1 : 0;
}
