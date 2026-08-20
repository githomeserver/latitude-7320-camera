/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Copyright (C) 2026, Sahan Nissanka
 *
 * Motion-adaptive temporal denoise for the software ISP.
 */

#include "temporal_denoise.h"

#include <algorithm>
#include <string.h>

namespace libcamera {

void TemporalDenoise::configure(float alpha, uint16_t threshold)
{
	if (alpha < 0.01f)
		alpha = 0.01f;
	else if (alpha > 1.0f)
		alpha = 1.0f;
	alpha_ = alpha;
	threshold_ = threshold ? threshold : 1;
}

void TemporalDenoise::apply(uint16_t *frame, size_t count)
{
	if (alpha_ >= 1.0f) {
		motionFraction_ = 1.0f;
		return;
	}

	/*
	 * First frame, or a geometry change: seed the history and emit the
	 * frame untouched. Blending against a stale buffer of a different size
	 * would be worse than not denoising at all.
	 */
	if (history_.size() != count) {
		history_.assign(frame, frame + count);
		motionFraction_ = 1.0f;
		return;
	}

	/*
	 * Motion is decided over runs of kBlock samples rather than per sample,
	 * and each run's mean |cur - prev| has the frame's own noise floor
	 * subtracted from it first. The runs are linear, not square: at this
	 * width one run is about a fifth of a Bayer row, which is compact
	 * enough to localise motion and avoids the addressing a 2D tile needs.
	 *
	 * Both parts are needed. Per-sample differences ARE the noise in a
	 * still scene, so using them directly drives the blend weight up and
	 * throttles the very averaging this exists to do - measured 1.44x
	 * instead of the 2.6x the recursion should give at alpha 0.25.
	 * Averaging |d| over a block does not help on its own either, because
	 * E[|d|] stays at the noise level however many samples go into it; only
	 * the *variance* of the estimate falls. Subtracting the floor is what
	 * actually separates "this moved" from "this is a sensor".
	 *
	 * The floor is estimated from the frame itself, as the 10th percentile
	 * of the block means, so it tracks exposure and analogue gain with no
	 * tuning. In a still scene almost every block is noise, so a low
	 * percentile is the noise level by construction.
	 */
	/*
	 * Motion is decided over square TILES when the geometry is known.
	 *
	 * It used to be runs of consecutive samples, which at this width is a
	 * horizontal strip a fifth of a row wide. A moving edge updated some
	 * strips and not others and left horizontal seams across it, which reads
	 * as interlacing combing - the most obvious artefact the filter produced.
	 *
	 * Each tile's mean |cur - prev| has the frame's own noise floor
	 * subtracted before it counts as motion. Both parts are needed:
	 * per-sample differences ARE the noise in a still scene, so using them
	 * directly throttles the averaging (measured 1.44x instead of 2.6x); and
	 * averaging |d| alone does not help, because E[|d|] stays at the noise
	 * level however many samples go into it. Only subtracting the floor
	 * separates "this moved" from "this is a sensor".
	 */
	const bool tiled = width_ > 0 && height_ > 0 &&
			   (size_t)width_ * height_ <= count;
	const unsigned int tx = tiled ? (width_ + kTile - 1) / kTile : 0;
	const unsigned int ty = tiled ? (height_ + kTile - 1) / kTile : 0;
	const unsigned int blocks = tiled ? tx * ty
					  : (unsigned int)((count + kBlock - 1) / kBlock);
	blockMotion_.resize(blocks);

	auto tileBounds = [&](unsigned int b, unsigned int &x0, unsigned int &x1,
			      unsigned int &y0, unsigned int &y1) {
		const unsigned int bx = b % tx, by = b / tx;
		x0 = bx * kTile; x1 = std::min(x0 + kTile, width_);
		y0 = by * kTile; y1 = std::min(y0 + kTile, height_);
	};

	for (unsigned int b = 0; b < blocks; b++) {
		uint32_t acc = 0;
		unsigned int n = 0;
		if (tiled) {
			unsigned int x0, x1, y0, y1;
			tileBounds(b, x0, x1, y0, y1);
			for (unsigned int y = y0; y < y1; y += 2) {
				const size_t row = (size_t)y * width_;
				for (unsigned int x = x0; x < x1; x += 2) {
					int32_t d = (int32_t)frame[row + x] -
						    (int32_t)history_[row + x];
					acc += d < 0 ? -d : d;
					n++;
				}
			}
		} else {
			const size_t s0 = (size_t)b * kBlock;
			const size_t s1 = std::min(s0 + kBlock, count);
			for (size_t i = s0; i < s1; i += 4) {
				int32_t d = (int32_t)frame[i] - (int32_t)history_[i];
				acc += d < 0 ? -d : d;
				n++;
			}
		}
		blockMotion_[b] = (uint16_t)(n ? acc / n : 0);
	}

	/* nth_element, not sort: only the 10th percentile is wanted. */
	scratch_.assign(blockMotion_.begin(), blockMotion_.end());
	const size_t k = scratch_.size() / 10;
	std::nth_element(scratch_.begin(), scratch_.begin() + k, scratch_.end());
	const int32_t floor = scratch_[k];

	const int32_t aFix = static_cast<int32_t>(alpha_ * 256.0f + 0.5f);
	const int32_t thr = threshold_;
	size_t moving = 0;

	auto weightOf = [&](unsigned int b) -> int32_t {
		int32_t m = (int32_t)blockMotion_[b] - floor;
		if (m < 0)
			m = 0;
		return m >= thr ? 256 : aFix + (256 - aFix) * m / thr;
	};

	for (unsigned int b = 0; b < blocks; b++) {
		const int32_t w = weightOf(b);
		if (w > 200)
			moving++;

		if (tiled) {
			unsigned int x0, x1, y0, y1;
			tileBounds(b, x0, x1, y0, y1);
			for (unsigned int y = y0; y < y1; y++) {
				const size_t row = (size_t)y * width_;
				for (unsigned int x = x0; x < x1; x++) {
					const size_t i = row + x;
					const int32_t cur = frame[i], prev = history_[i];
					const int32_t out = prev + ((cur - prev) * w >> 8);
					const uint16_t v = (uint16_t)(out < 0 ? 0 : out);
					frame[i] = v;
					history_[i] = v;
				}
			}
		} else {
			const size_t s0 = (size_t)b * kBlock;
			const size_t s1 = std::min(s0 + kBlock, count);
			for (size_t i = s0; i < s1; i++) {
				const int32_t cur = frame[i], prev = history_[i];
				const int32_t out = prev + ((cur - prev) * w >> 8);
				const uint16_t v = (uint16_t)(out < 0 ? 0 : out);
				frame[i] = v;
				history_[i] = v;
			}
		}
	}

	motionFraction_ = blocks ? static_cast<float>(moving) / blocks : 0.0f;
}

} /* namespace libcamera */
