// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * Does the adaptive IR coefficient land where the algebra says it should?
 *
 * Builds synthetic RGB-IR frames whose IR plane has a KNOWN mean and a KNOWN
 * noise sigma, runs them through convertSharp(), and compares the coefficient
 * the filter settled on against the closed form
 *
 *     k = a * I^2 / (I^2 + s^2)
 *
 * A shrinkage rule that is not checked against its own formula is just a
 * plausible-looking division.
 *
 * Build:  g++ -O2 -o /tmp/test-iradapt test-iradapt.cpp rgbir_to_bayer.cpp
 */

#include "rgbir_to_bayer.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <random>
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

constexpr unsigned int kW = 256, kH = 256;
constexpr uint16_t kBlack = 64;
constexpr unsigned int kBits = 10;

/*
 * One frame. Colour sits at a fixed level; only the IR plane is controlled,
 * since that is what the rule reads. Noise goes on every channel so the frame
 * is not unrealistically quiet, but only IR's sigma is the variable under test.
 */
void makeFrame(std::vector<uint8_t> &buf, double irMean, double irSigma,
	       std::mt19937 &rng, bool clipIr = false)
{
	std::normal_distribution<double> nIr(irMean, irSigma);
	std::normal_distribution<double> nCol(400.0, 8.0);
	const int maxV = (1 << kBits) - 1;

	for (unsigned int y = 0; y < kH; y++) {
		for (unsigned int x = 0; x < kW; x++) {
			const RgbIrToBayer::Channel c = kPattern[(y % 4) * 4 + (x % 4)];
			double v;
			if (c == RgbIrToBayer::Infrared)
				v = clipIr ? maxV : kBlack + nIr(rng);
			else
				v = kBlack + nCol(rng);
			int iv = (int)std::lround(v);
			iv = iv < 0 ? 0 : (iv > maxV ? maxV : iv);
			const size_t o = (size_t)(y * kW + x) * 2;
			buf[o] = iv & 0xff;
			buf[o + 1] = (iv >> 8) & 0xff;
		}
	}
}

/* Run enough frames for the 1/8 ramp to settle, and report where it lands. */
float settle(RgbIrToBayer &conv, double irMean, double irSigma, bool clipIr = false)
{
	std::mt19937 rng(12345);
	std::vector<uint8_t> src((size_t)kW * kH * 2);
	std::vector<uint16_t> dst((size_t)(kW / 2) * (kH / 2));
	for (int i = 0; i < 80; i++) {
		makeFrame(src, irMean, irSigma, rng, clipIr);
		conv.convertSharp(src.data(), kW, kH, kW * 2, dst.data(),
				  (kW / 2) * 2, RgbIrToBayer::Order::GRBG);
	}
	return conv.effectiveIrSubtract();
}

int failures = 0;

void expect(const char *what, double got, double want, double tol)
{
	const bool ok = std::fabs(got - want) <= tol;
	if (!ok)
		failures++;
	printf("  %-46s got %6.3f  want %6.3f +/- %.2f  %s\n",
	       what, got, want, tol, ok ? "ok" : "FAIL");
}

} /* namespace */

int main()
{
	const float a = 2.0f;

	printf("Wiener shrinkage of the IR coefficient (a = %.1f)\n\n", a);

	/*
	 * The two regimes measured on the real sensor. Signal is stated
	 * black-level relative, which is what the filter works in.
	 */
	struct { const char *name; double mean, sigma; } cases[] = {
		{ "clean IR  (bright: I=61, s=13.6)",  61.0, 13.6 },
		{ "noisy IR  (dark room: I=3, s=5.2)",  3.0,  5.2 },
		{ "marginal IR (I=8, s=10)",            8.0, 10.0 },
		{ "very clean IR (I=300, s=10)",      300.0, 10.0 },
		{ "IR is pure noise (I=1, s=20)",       1.0, 20.0 },
	};

	for (const auto &c : cases) {
		RgbIrToBayer conv(kPattern, kBlack, kBits);
		conv.setIrSubtract(a);
		conv.setIrAdaptive(true);
		conv.setSharpness(0.5f);
		/*
		 * sigma is quoted per IR PIXEL, but what gets subtracted is the
		 * cell average of counts_[Infrared] of them, so the noise on the
		 * estimate is sigma/sqrt(n) - four here, so half.
		 */
		const double sCell = c.sigma / 2.0;
		const double want = a * (c.mean * c.mean) /
				    (c.mean * c.mean + sCell * sCell);
		expect(c.name, settle(conv, c.mean, c.sigma), want, 0.12);
	}

	printf("\nguards\n\n");

	/* Adaptive off must leave the tuned coefficient exactly alone. */
	{
		RgbIrToBayer conv(kPattern, kBlack, kBits);
		conv.setIrSubtract(a);
		conv.setIrAdaptive(false);
		expect("adaptive off holds the set value", settle(conv, 3.0, 5.2), a, 0.001);
	}

	/*
	 * A fully clipped IR plane reports neither level nor noise. The filter
	 * must hold its previous value rather than read the clamp as clean
	 * signal and drive k to maximum.
	 */
	{
		RgbIrToBayer conv(kPattern, kBlack, kBits);
		conv.setIrSubtract(a);
		conv.setIrAdaptive(true);
		const float dark = settle(conv, 3.0, 5.2);
		const float after = settle(conv, 0.0, 0.0, /*clipIr=*/true);
		expect("clipped IR holds, does not jump to a", after, dark, 0.001);
	}

	/*
	 * Texture must not be mistaken for noise. Same IR mean and sigma as the
	 * bright case, but every fourth cell carries a large IR step; the median
	 * should shrug it off where a mean would not.
	 */
	{
		RgbIrToBayer conv(kPattern, kBlack, kBits);
		conv.setIrSubtract(a);
		conv.setIrAdaptive(true);
		std::mt19937 rng(999);
		std::vector<uint8_t> src((size_t)kW * kH * 2);
		std::vector<uint16_t> dst((size_t)(kW / 2) * (kH / 2));
		for (int i = 0; i < 80; i++) {
			makeFrame(src, 61.0, 13.6, rng);
			for (unsigned int y = 0; y < kH; y++)
				for (unsigned int x = 2; x < kW; x += 16) {
					const size_t o = (size_t)(y * kW + x) * 2;
					int v = (src[o] | (src[o + 1] << 8)) + 300;
					v = v > 1023 ? 1023 : v;
					src[o] = v & 0xff; src[o + 1] = (v >> 8) & 0xff;
				}
			conv.convertSharp(src.data(), kW, kH, kW * 2, dst.data(),
					  (kW / 2) * 2, RgbIrToBayer::Order::GRBG);
		}
		const double sCell = 13.6 / 2.0;
		const double clean = a * (61.0 * 61.0) / (61.0 * 61.0 + sCell * sCell);
		expect("IR texture does not collapse k", conv.effectiveIrSubtract(),
		       clean, 0.25);
	}

	/*
	 * The point of the whole exercise: one frame holding both a lit region
	 * and a dim one must not get one compromise coefficient. A frame-wide
	 * mean would be dragged up by the lit part - measured on real hardware,
	 * a dark room still reported 1.99 - leaving the dim part, where the
	 * grain actually is, subtracting noise at full strength.
	 */
	printf("\nper-cell response\n\n");
	{
		RgbIrToBayer conv(kPattern, kBlack, kBits);
		conv.setIrSubtract(a);
		conv.setIrAdaptive(true);
		settle(conv, 61.0, 13.6);	/* fixes sigma at 13.6/2 */

		const double sCell = 13.6 / 2.0;
		for (int ir : { 3, 8, 20, 61, 300 }) {
			const double want = a * (double)ir * ir /
					    ((double)ir * ir + sCell * sCell);
			char label[64];
			snprintf(label, sizeof(label), "cell IR %3d -> k", ir);
			expect(label, conv.irCoefficientAt(ir), want, 0.06);
		}
		const bool ordered = conv.irCoefficientAt(3) < conv.irCoefficientAt(61);
		printf("  %-46s %s\n", "dim cells shrink harder than lit ones",
		       ordered ? "ok" : "FAIL");
		if (!ordered)
			failures++;
	}

	/*
	 * A blown highlight must come out white. Every channel including IR
	 * pins at full scale there, so an unmodified subtraction removes k
	 * times the whole signal and the brightest thing in the frame clamps
	 * to black - which is what the camera actually did around a ceiling
	 * light before the rolloff existed.
	 */
	printf("\nhighlights\n\n");
	{
		RgbIrToBayer conv(kPattern, kBlack, kBits);
		conv.setIrSubtract(a);
		conv.setIrAdaptive(false);
		conv.setSharpness(0.5f);

		const int maxV = (1 << kBits) - 1;
		std::vector<uint8_t> src((size_t)kW * kH * 2);
		std::vector<uint16_t> dst((size_t)(kW / 2) * (kH / 2));

		/* \a colour on R, G and B; \a ir on the infrared positions. */
		auto fill = [&](int colour, int ir) {
			for (unsigned int y = 0; y < kH; y++)
				for (unsigned int x = 0; x < kW; x++) {
					const bool isIr = kPattern[(y % 4) * 4 + (x % 4)] ==
							  RgbIrToBayer::Infrared;
					const int v = isIr ? ir : colour;
					const size_t o = (size_t)(y * kW + x) * 2;
					src[o] = v & 0xff;
					src[o + 1] = (v >> 8) & 0xff;
				}
			conv.convertSharp(src.data(), kW, kH, kW * 2, dst.data(),
					  (kW / 2) * 2, RgbIrToBayer::Order::GRBG);
			double s = 0;
			for (uint16_t v : dst) s += v;
			return s / dst.size();
		};

		expect("clipped white stays white", fill(maxV, maxV), maxV, 2.0);

		/*
		 * Well below the knee the rolloff must change nothing, so the
		 * result is exactly the plain arithmetic. IR at a tenth of the
		 * colour channels is roughly the ratio this sensor shows.
		 */
		const int colour = 400, ir = 100;
		const double want = kBlack + (colour - kBlack) - a * (ir - kBlack);
		expect("below the knee, plain subtraction", fill(colour, ir), want, 2.0);

		/*
		 * And the fade is monotonic: pushing the same scene brighter must
		 * never make it darker on the way to white.
		 */
		bool mono = true;
		double prev = -1;
		for (int lv = 700; lv <= maxV; lv += 20) {
			const double v = fill(lv, lv);
			if (v < prev - 1.0)
				mono = false;
			prev = v;
		}
		printf("  %-46s %s\n", "brighter never comes out darker",
		       mono ? "ok" : "FAIL");
		if (!mono)
			failures++;
	}

	printf("\n%s\n", failures ? "FAILURES" : "all checks passed");
	return failures ? 1 : 0;
}
