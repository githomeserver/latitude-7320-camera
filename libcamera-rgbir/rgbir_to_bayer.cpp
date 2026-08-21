/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Copyright (C) 2026, Sahan Nissanka
 *
 * RGB-IR mosaic to Bayer conversion for libcamera's software ISP.
 */

#include "rgbir_to_bayer.h"

#include <algorithm>
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

	/*
	 * Optional infrared subtraction. Every colour photosite responds to
	 * near-infrared as well, so each colour channel carries an IR pedestal
	 * that washes the image out. Removing k times the cell's IR average
	 * restores saturation, at the cost of adding IR's noise to all three.
	 * Values are still black-level-relative here, which is what makes a
	 * plain subtraction correct.
	 */
	if (irSubtract_ > 0.0f && counts_[Infrared]) {
		const int32_t ir = sum[Infrared] / counts_[Infrared];
		const int32_t d = static_cast<int32_t>(irSubtract_ * ir);
		g -= d;
		r -= d;
		b -= d;
	}

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

void RgbIrToBayer::cellValuesSharp(const uint8_t *lines[4], unsigned int cx,
				   unsigned int cols, unsigned int cy,
				   unsigned int rows, const ShadingMap *shading,
				   uint16_t G[4], uint16_t &R, uint16_t &B) const
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

	int32_t r = counts_[Red] ? sum[Red] / counts_[Red] : 0;
	int32_t b = counts_[Blue] ? sum[Blue] / counts_[Blue] : 0;

	/*
	 * Green per 2x2 quadrant. Derived from positions_ rather than assumed,
	 * so a differently-phased 4x4 pattern still works. A quadrant with no
	 * green falls back to the cell mean instead of emitting a hole.
	 */
	const int32_t gCell = counts_[Green] ? sum[Green] / counts_[Green] : 0;
	int32_t g[4];
	for (unsigned int q = 0; q < 4; q++) {
		const unsigned int qy = q >> 1, qx = q & 1;
		int32_t acc = 0;
		unsigned int n = 0;
		for (uint8_t k = 0; k < counts_[Green]; k++) {
			const uint8_t pos = positions_[Green][k];
			if ((pos >> 2) / 2 == qy && (pos & 3) / 2 == qx) {
				acc += cell[pos];
				n++;
			}
		}
		const int32_t gq = n ? acc / static_cast<int32_t>(n) : gCell;
		/*
		 * Blend toward the cell mean. The quadrant mean carries the
		 * detail and the cell mean carries the lower noise, so this
		 * slides between them rather than forcing a choice.
		 */
		g[q] = gCell + (int32_t)(sharpness_ * (float)(gq - gCell));
	}

	if (irSubtract_ > 0.0f && counts_[Infrared]) {
		const int32_t ir = sum[Infrared] / counts_[Infrared];
		const int32_t d = static_cast<int32_t>(irSubtract_ * ir);
		for (unsigned int q = 0; q < 4; q++)
			g[q] -= d;
		r -= d;
		b -= d;
	}

	if (shading) {
		const ShadingMap &s = *shading;
		const uint32_t one = s.one ? s.one : 1;
		if (s.gains[Green]) {
			const uint32_t gain = sampleGain(s.gains[Green], s.width, s.height, cx, cols, cy, rows);
			for (unsigned int q = 0; q < 4; q++)
				g[q] = (int32_t)((int64_t)g[q] * gain / one);
		}
		if (s.gains[Red])
			r = (int32_t)((int64_t)r * sampleGain(s.gains[Red], s.width, s.height, cx, cols, cy, rows) / one);
		if (s.gains[Blue])
			b = (int32_t)((int64_t)b * sampleGain(s.gains[Blue], s.width, s.height, cx, cols, cy, rows) / one);
	}

	const int32_t maxVal = maxValue_;
	auto clamp = [maxVal](int32_t v) -> uint16_t {
		if (v < 0)
			return 0;
		return v > maxVal ? (uint16_t)maxVal : (uint16_t)v;
	};

	for (unsigned int q = 0; q < 4; q++)
		G[q] = clamp(g[q] + blackLevel_);
	R = clamp(r + blackLevel_);
	B = clamp(b + blackLevel_);
}

int RgbIrToBayer::convertSharp(const uint8_t *src, unsigned int srcWidth,
			       unsigned int srcHeight, unsigned int srcStride,
			       uint16_t *dst, unsigned int dstStride,
			       Order order, const ShadingMap *shading) const
{
	if (srcWidth % 4 || srcHeight % 4)
		return -EINVAL;

	const unsigned int cols = srcWidth / 4;
	const unsigned int rows = srcHeight / 4;
	const unsigned int dstPitch = dstStride / 2;

	/*
	 * Each cell row produces output rows 2*cy and 2*cy+1, so converting
	 * output rows [activeY0_, activeY1_) means cell rows [y0/2, (y1-1)/2].
	 * Shading and the IR average are per-cell and do not depend on
	 * neighbouring cells, so skipping rows changes nothing in the rows that
	 * are kept.
	 */
	unsigned int cy0 = 0, cy1 = rows;
	if (activeY1_ > activeY0_) {
		cy0 = activeY0_ / 2;
		cy1 = std::min(rows, (activeY1_ + 1) / 2 + 1);
	}

	/*
	 * Green is written as it is computed; red and blue are buffered so they
	 * can be smoothed across neighbouring cells first. Chroma carries most
	 * of the visible noise here - on a flat patch, luma sd 5.64 against Cr
	 * 10.03 - because red occupies 2 of 16 mosaic positions and the colour
	 * matrix then amplifies that row 1.90x. Blurring it costs almost nothing
	 * real, since one red value already covers a 4x4 block of sensor pixels.
	 */
	const bool blurChroma = chromaBlur_ > 0;
	if (blurChroma) {
		chromaR_.assign((size_t)cols * rows, 0);
		chromaB_.assign((size_t)cols * rows, 0);
	}

	for (unsigned int cy = cy0; cy < cy1; cy++) {
		const uint8_t *lines[4];
		for (unsigned int i = 0; i < 4; i++)
			lines[i] = src + (cy * 4 + i) * srcStride;

		uint16_t *out0 = dst + (cy * 2) * dstPitch;
		uint16_t *out1 = out0 + dstPitch;

		for (unsigned int cx = 0; cx < cols; cx++) {
			uint16_t G[4], R, B;
			cellValuesSharp(lines, cx, cols, cy, rows, shading, G, R, B);

			/*
			 * The quad's green slots sit at its top-left and
			 * bottom-right, which is exactly where the cell's
			 * top-left and bottom-right quadrants are. The other
			 * two quadrant greens have no slot in a 2x2 Bayer quad
			 * and are necessarily dropped.
			 */
			out0[cx * 2 + 0] = G[0];
			out1[cx * 2 + 1] = G[3];

			if (blurChroma) {
				chromaR_[(size_t)cy * cols + cx] = R;
				chromaB_[(size_t)cy * cols + cx] = B;
			} else {
				const uint16_t t1 = order == Order::GRBG ? R : B;
				const uint16_t b0 = order == Order::GRBG ? B : R;
				out0[cx * 2 + 1] = t1;
				out1[cx * 2 + 0] = b0;
			}
		}
	}

	if (blurChroma) {
		/*
		 * Box average over a (2r+1)^2 cell neighbourhood, clamped to the
		 * converted band so it never reads rows this frame did not fill.
		 */
		const int r = (int)chromaBlur_;
		for (unsigned int cy = cy0; cy < cy1; cy++) {
			uint16_t *out0 = dst + (cy * 2) * dstPitch;
			uint16_t *out1 = out0 + dstPitch;
			const int y0 = std::max((int)cy0, (int)cy - r);
			const int y1 = std::min((int)cy1 - 1, (int)cy + r);

			for (unsigned int cx = 0; cx < cols; cx++) {
				const int x0 = std::max(0, (int)cx - r);
				const int x1 = std::min((int)cols - 1, (int)cx + r);
				uint32_t sr = 0, sb = 0;
				unsigned int n = 0;
				for (int y = y0; y <= y1; y++) {
					const size_t row = (size_t)y * cols;
					for (int x = x0; x <= x1; x++) {
						sr += chromaR_[row + x];
						sb += chromaB_[row + x];
						n++;
					}
				}
				const uint16_t R = (uint16_t)(sr / n);
				const uint16_t B = (uint16_t)(sb / n);
				const uint16_t t1 = order == Order::GRBG ? R : B;
				const uint16_t b0 = order == Order::GRBG ? B : R;
				out0[cx * 2 + 1] = t1;
				out1[cx * 2 + 0] = b0;
			}
		}
	}

	return 0;
}

} /* namespace libcamera */
