/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Copyright (C) 2026, Sahan Nissanka
 *
 * RGB-IR mosaic to Bayer conversion for libcamera's software ISP.
 */

#include "rgbir_to_bayer.h"

#include <errno.h>
#include <string.h>

namespace libcamera {

RgbIrToBayer::RgbIrToBayer(const Channel pattern[16], uint16_t blackLevel,
			   unsigned int bitDepth)
	: blackLevel_(blackLevel),
	  maxValue_(static_cast<uint16_t>((1u << bitDepth) - 1))
{
	memset(counts_, 0, sizeof(counts_));
	memset(positions_, 0, sizeof(positions_));

	for (uint8_t i = 0; i < 16; i++) {
		Channel c = pattern[i];
		/*
		 * Eight is the most any channel can occupy in a 4x4 cell that
		 * also contains three others; green hits exactly that.
		 */
		if (counts_[c] < 8)
			positions_[c][counts_[c]++] = i;
	}
}

namespace {

/*
 * Bilinear sample of a gain map. The map is far coarser than the image - 63x47
 * against 648x486 here - so nearest-neighbour would put visible steps in flat
 * areas, which is exactly where shading correction is most noticeable.
 */
inline uint32_t sampleGain(const uint16_t *map, unsigned int mw, unsigned int mh,
			   unsigned int x, unsigned int cols,
			   unsigned int y, unsigned int rows)
{
	if (cols < 2 || rows < 2)
		return map[0];

	unsigned int gx16 = x * (mw - 1) * 16 / (cols - 1);
	unsigned int gy16 = y * (mh - 1) * 16 / (rows - 1);
	unsigned int x0 = gx16 >> 4, y0 = gy16 >> 4;
	unsigned int fx = gx16 & 15, fy = gy16 & 15;
	unsigned int x1 = x0 + 1 < mw ? x0 + 1 : x0;
	unsigned int y1 = y0 + 1 < mh ? y0 + 1 : y0;

	uint32_t a = map[y0 * mw + x0], b = map[y0 * mw + x1];
	uint32_t c = map[y1 * mw + x0], d = map[y1 * mw + x1];
	uint32_t top = a * (16 - fx) + b * fx;
	uint32_t bot = c * (16 - fx) + d * fx;
	return (top * (16 - fy) + bot * fy) >> 8;
}

} /* namespace */

void RgbIrToBayer::cellValues(const uint8_t *lines[4], unsigned int cx,
			      unsigned int cols, unsigned int cy,
			      unsigned int rows, const ShadingMap *shading,
			      uint16_t &G, uint16_t &R, uint16_t &B) const
{
	int32_t cell[16];
	for (unsigned int dy = 0; dy < 4; dy++) {
		const uint8_t *p = lines[dy] + (cx * 4) * 2;
		for (unsigned int dx = 0; dx < 4; dx++) {
			int32_t v = p[0] | (p[1] << 8);
			cell[dy * 4 + dx] = v - blackLevel_;
			p += 2;
		}
	}

	int32_t sum[4] = { 0, 0, 0, 0 };
	for (uint8_t c = 0; c < 4; c++)
		for (uint8_t k = 0; k < counts_[c]; k++)
			sum[c] += cell[positions_[c][k]];

	int32_t g = counts_[Green] ? sum[Green] / counts_[Green] : 0;
	int32_t r = counts_[Red] ? sum[Red] / counts_[Red] : 0;
	int32_t b = counts_[Blue] ? sum[Blue] / counts_[Blue] : 0;

	if (shading) {
		const ShadingMap &s = *shading;
		const uint32_t one = s.one ? s.one : 1;
		if (s.gains[Green])
			g = (int32_t)((int64_t)g * sampleGain(s.gains[Green], s.width, s.height, cx, cols, cy, rows) / one);
		if (s.gains[Red])
			r = (int32_t)((int64_t)r * sampleGain(s.gains[Red], s.width, s.height, cx, cols, cy, rows) / one);
		if (s.gains[Blue])
			b = (int32_t)((int64_t)b * sampleGain(s.gains[Blue], s.width, s.height, cx, cols, cy, rows) / one);
	}

	/*
	 * Re-add the pedestal. Downstream BlackLevel expects to subtract it;
	 * handing it pre-subtracted data would make it subtract twice and
	 * crush the shadows.
	 */
	const int32_t maxVal = maxValue_;
	auto clamp = [maxVal](int32_t v) -> uint16_t {
		if (v < 0)
			return 0;
		return v > maxVal ? (uint16_t)maxVal : (uint16_t)v;
	};

	G = clamp(g + blackLevel_);
	R = clamp(r + blackLevel_);
	B = clamp(b + blackLevel_);
}

int RgbIrToBayer::convertSameSize(const uint8_t *src, unsigned int srcWidth,
				  unsigned int srcHeight, unsigned int srcStride,
				  uint16_t *dst, unsigned int dstStride,
				  Order order, const ShadingMap *shading) const
{
	if (srcWidth % 4 || srcHeight % 4)
		return -EINVAL;

	const unsigned int cols = srcWidth / 4;
	const unsigned int rows = srcHeight / 4;
	const unsigned int dstPitch = dstStride / 2;

	for (unsigned int cy = 0; cy < rows; cy++) {
		const uint8_t *lines[4];
		for (unsigned int i = 0; i < 4; i++)
			lines[i] = src + (cy * 4 + i) * srcStride;

		uint16_t *o[4];
		for (unsigned int i = 0; i < 4; i++)
			o[i] = dst + (cy * 4 + i) * dstPitch;

		for (unsigned int cx = 0; cx < cols; cx++) {
			uint16_t G, R, B;
			cellValues(lines, cx, cols, cy, rows, shading, G, R, B);

			/* Four identical 2x2 cells, tiled, in the asked order. */
			const uint16_t t1 = order == Order::GRBG ? R : B;
			const uint16_t b0 = order == Order::GRBG ? B : R;
			for (unsigned int i = 0; i < 4; i += 2) {
				uint16_t *top = o[i] + cx * 4;
				uint16_t *bot = o[i + 1] + cx * 4;
				top[0] = G; top[1] = t1; top[2] = G; top[3] = t1;
				bot[0] = b0; bot[1] = G; bot[2] = b0; bot[3] = G;
			}
		}
	}

	return 0;
}

int RgbIrToBayer::convert(const uint8_t *src, unsigned int srcWidth,
			  unsigned int srcHeight, unsigned int srcStride,
			  uint16_t *dst, unsigned int dstStride,
			  const ShadingMap *shading) const
{
	if (srcWidth % 4 || srcHeight % 4)
		return -EINVAL;

	const unsigned int cols = srcWidth / 4;
	const unsigned int rows = srcHeight / 4;
	const unsigned int dstPitch = dstStride / 2;

	for (unsigned int cy = 0; cy < rows; cy++) {
		const uint8_t *lines[4];
		for (unsigned int i = 0; i < 4; i++)
			lines[i] = src + (cy * 4 + i) * srcStride;

		uint16_t *out0 = dst + (cy * 2) * dstPitch;
		uint16_t *out1 = out0 + dstPitch;

		for (unsigned int cx = 0; cx < cols; cx++) {
			uint16_t G, R, B;
			cellValues(lines, cx, cols, cy, rows, shading, G, R, B);

			/* GRBG: G R / B G */
			out0[cx * 2 + 0] = G;
			out0[cx * 2 + 1] = R;
			out1[cx * 2 + 0] = B;
			out1[cx * 2 + 1] = G;
		}
	}

	return 0;
}

} /* namespace libcamera */
