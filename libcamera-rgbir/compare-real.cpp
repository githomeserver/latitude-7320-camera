// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * Run convert() and convertSharp() over the SAME real sensor frame and report
 * how much green detail each keeps.
 *
 * The on-camera A/B was inconclusive because the scene was clipped and almost
 * featureless, so neither path had anything at Nyquist to preserve. Feeding one
 * captured raw frame to both removes the scene, the AGC and the AWB from the
 * comparison entirely.
 *
 * Capture a frame with:
 *   cam -c1 -s role=raw -C120 --file='raw#.bin'
 *
 * Build:  g++ -O2 -o compare-real compare-real.cpp rgbir_to_bayer.cpp
 * Run:    ./compare-real raw.bin [width height]
 */

#include "rgbir_to_bayer.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <vector>

using namespace libcamera;

namespace {

const RgbIrToBayer::Channel kPattern[16] = {
	RgbIrToBayer::Green,    RgbIrToBayer::Infrared, RgbIrToBayer::Green,    RgbIrToBayer::Infrared,
	RgbIrToBayer::Red,      RgbIrToBayer::Green,    RgbIrToBayer::Blue,     RgbIrToBayer::Green,
	RgbIrToBayer::Green,    RgbIrToBayer::Infrared, RgbIrToBayer::Green,    RgbIrToBayer::Infrared,
	RgbIrToBayer::Blue,     RgbIrToBayer::Green,    RgbIrToBayer::Red,      RgbIrToBayer::Green,
};

/*
 * Green sits at (even,even) and (odd,odd) of a GRBG quad. Pull the (even,even)
 * lattice out as a plain image: it is a regular grid, so ordinary difference
 * metrics mean what they usually mean.
 */
std::vector<double> greenLattice(const std::vector<uint16_t> &bayer,
				 unsigned int w, unsigned int h,
				 unsigned int &gw, unsigned int &gh)
{
	gw = w / 2;
	gh = h / 2;
	std::vector<double> g(gw * gh);
	for (unsigned int y = 0; y < gh; y++)
		for (unsigned int x = 0; x < gw; x++)
			g[y * gw + x] = bayer[(y * 2) * w + (x * 2)];
	return g;
}

double meanAbsDiffV(const std::vector<double> &g, unsigned int gw, unsigned int gh)
{
	double tot = 0.0;
	unsigned int n = 0;
	for (unsigned int y = 0; y + 1 < gh; y++)
		for (unsigned int x = 0; x < gw; x++) {
			tot += std::fabs(g[(y + 1) * gw + x] - g[y * gw + x]);
			n++;
		}
	return n ? tot / n : 0.0;
}

double laplacianVar(const std::vector<double> &g, unsigned int gw, unsigned int gh)
{
	std::vector<double> l;
	l.reserve(gw * gh);
	for (unsigned int y = 1; y + 1 < gh; y++)
		for (unsigned int x = 1; x + 1 < gw; x++)
			l.push_back(-4 * g[y * gw + x] + g[(y - 1) * gw + x] +
				    g[(y + 1) * gw + x] + g[y * gw + x - 1] +
				    g[y * gw + x + 1]);
	if (l.empty())
		return 0.0;
	double m = 0.0;
	for (double v : l) m += v;
	m /= l.size();
	double var = 0.0;
	for (double v : l) var += (v - m) * (v - m);
	return var / l.size();
}

/*
 * The two green slots of a quad. convert() writes one cell average to both, so
 * this is identically zero for it, by construction. Anything non-zero is the
 * real intra-cell gradient that convertSharp recovers.
 */
double intraQuadGreenSpread(const std::vector<uint16_t> &bayer,
			    unsigned int w, unsigned int h)
{
	double tot = 0.0;
	unsigned int n = 0;
	for (unsigned int y = 0; y + 1 < h; y += 2)
		for (unsigned int x = 0; x + 1 < w; x += 2) {
			tot += std::fabs((double)bayer[(y + 1) * w + x + 1] -
					 (double)bayer[y * w + x]);
			n++;
		}
	return n ? tot / n : 0.0;
}

/*
 * Noise floor: standard deviation inside the flattest blocks. Averaging eight
 * greens instead of two divides read noise by sqrt(8) rather than sqrt(2), so
 * the sharper path MUST be noisier. Measuring it keeps "sharper" honest.
 */
double flatBlockNoise(const std::vector<double> &g, unsigned int gw, unsigned int gh)
{
	std::vector<double> sds;
	const unsigned int B = 16;
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
	return sds[sds.size() / 10];   /* 10th percentile: flattest blocks */
}

} /* namespace */

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s <raw.bin> [width height]\n", argv[0]);
		return 2;
	}
	const unsigned int W = argc > 3 ? atoi(argv[2]) : 2592;
	const unsigned int H = argc > 3 ? atoi(argv[3]) : 1944;

	FILE *f = fopen(argv[1], "rb");
	if (!f) { perror("open"); return 1; }
	std::vector<uint8_t> src((size_t)W * H * 2);
	if (fread(src.data(), 1, src.size(), f) != src.size()) {
		fprintf(stderr, "short read: expected %zu bytes for %ux%u\n", src.size(), W, H);
		fclose(f);
		return 1;
	}
	fclose(f);

	RgbIrToBayer conv(kPattern, 64, 10);
	conv.setIrSubtract(1.0f);
	if (const char *sh = getenv("SHARPNESS"))
		conv.setSharpness(atof(sh));

	const unsigned int ow = W / 2, oh = H / 2;
	std::vector<uint16_t> a(ow * oh, 0), b(ow * oh, 0);
	if (conv.convert(src.data(), W, H, W * 2, a.data(), ow * 2,
			 RgbIrToBayer::Order::GBRG) != 0 ||
	    conv.convertSharp(src.data(), W, H, W * 2, b.data(), ow * 2,
			      RgbIrToBayer::Order::GBRG) != 0) {
		fprintf(stderr, "conversion failed\n");
		return 1;
	}

	unsigned int gw, gh;
	std::vector<double> ga = greenLattice(a, ow, oh, gw, gh);
	std::vector<double> gb = greenLattice(b, ow, oh, gw, gh);

	const double dva = meanAbsDiffV(ga, gw, gh), dvb = meanAbsDiffV(gb, gw, gh);
	const double lva = laplacianVar(ga, gw, gh), lvb = laplacianVar(gb, gw, gh);
	const double sa = intraQuadGreenSpread(a, ow, oh), sb = intraQuadGreenSpread(b, ow, oh);

	printf("  frame %ux%u -> bayer %ux%u, green lattice %ux%u\n\n", W, H, ow, oh, gw, gh);
	printf("  metric                       convert()   convertSharp()    ratio\n");
	printf("  mean |vertical diff|        %9.3f      %9.3f    %6.2fx\n", dva, dvb, dva > 0 ? dvb / dva : 0);
	printf("  laplacian variance          %9.1f      %9.1f    %6.2fx\n", lva, lvb, lva > 0 ? lvb / lva : 0);
	printf("  intra-quad green spread     %9.3f      %9.3f\n", sa, sb);
	const double na = flatBlockNoise(ga, gw, gh), nb = flatBlockNoise(gb, gw, gh);
	printf("  noise floor (flat blocks)   %9.3f      %9.3f    %6.2fx\n", na, nb, na > 0 ? nb / na : 0);
	printf("  detail-to-noise             %9.3f      %9.3f    %6.2fx\n",
	       na > 0 ? dva / na : 0, nb > 0 ? dvb / nb : 0,
	       (na > 0 && nb > 0 && dva > 0) ? (dvb / nb) / (dva / na) : 0);
	/* Optional side-by-side material: the two green lattices as PGM. */
	if (argc > 2 && strcmp(argv[2], "--dump") == 0) {
		auto pgm = [&](const char *path, const std::vector<double> &g) {
			FILE *o = fopen(path, "wb");
			if (!o) return;
			fprintf(o, "P5\n%u %u\n255\n", gw, gh);
			for (double v : g) {
				int p = (int)(v / 4.0);      /* 10-bit -> 8-bit */
				fputc(p < 0 ? 0 : (p > 255 ? 255 : p), o);
			}
			fclose(o);
		};
		pgm("/tmp/green_flat.pgm", ga);
		pgm("/tmp/green_sharp.pgm", gb);
		printf("  wrote /tmp/green_flat.pgm and /tmp/green_sharp.pgm\n");
	}

	printf("\n");
	if (sa > 0.001)
		printf("  WARNING: convert() should write one value to both green slots.\n");
	printf("  intra-quad spread is 0 for convert() by construction; %.2f for\n", sb);
	printf("  convertSharp is the real detail inside each cell that was being\n");
	printf("  averaged away.\n");
	return 0;
}
