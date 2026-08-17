/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Copyright (C) 2026, Sahan Nissanka
 *
 * RGB-IR mosaic to Bayer conversion for libcamera's software ISP.
 */

#pragma once

#include <stddef.h>
#include <stdint.h>

namespace libcamera {

/**
 * \brief Convert a 4x4 RGB-IR mosaic to a half-resolution Bayer image
 *
 * Some sensors - the OV5678 on the Dell Latitude 7320 Detachable among them -
 * use a 4x4 colour filter array with one infrared pixel in four:
 *
 *     G I G I
 *     R G B G
 *     G I G I
 *     B G R G
 *
 * The software ISP handles 2x2 mosaics only. Read as a 2x2 Bayer, the IR
 * pixels are mistaken for one colour channel and the red and blue pixels are
 * averaged into another, which destroys colour rather than merely degrading
 * it.
 *
 * Rather than teach the whole ISP a new mosaic, this converts to Bayer up
 * front, as Intel's own IPU6 hardware does in its "x2b_rgbir" block, after
 * which the existing debayer, statistics, AWB and CCM all work unmodified.
 *
 * The output is half the input dimensions, and that ratio is not a
 * compromise: a 4x4 RGB-IR cell holds exactly two red and two blue pixels,
 * and a 2x2 Bayer cell at half resolution needs exactly one of each. Chroma
 * maps across with nothing discarded - RGB-IR chroma density at half
 * resolution *is* Bayer density. Green averages four into one, the same
 * reduction the sensor's own binned mode performs, except that binning
 * averages IR in with colour and this does not.
 *
 * The IR pixels are dropped. Subtracting IR from the colour channels needs a
 * per-illuminant model and is left to a later change; on this hardware under
 * LED lighting the measured IR/G ratio is about 0.10, so the correction is
 * second order. Under tungsten it would not be.
 */
class RgbIrToBayer
{
public:
	/**
	 * \brief Bayer order of the generated output
	 *
	 * Must match what the consumer was configured for. Getting this wrong
	 * transposes red and blue, which is the exact fault this conversion
	 * exists to remove, so it is explicit rather than defaulted.
	 */
	enum class Order {
		GRBG,   /* G R / B G */
		GBRG,   /* G B / R G */
	};

	/** \brief Which channel sits at each position of the 4x4 cell */
	enum Channel : uint8_t {
		Green = 0,
		Infrared = 1,
		Red = 2,
		Blue = 3,
	};

	/**
	 * \brief Per-channel spatial gain map, e.g. lens shading
	 *
	 * Gains are applied before the mosaic is collapsed, which is the only
	 * point at which each pixel's channel is still known. Indexed by
	 * Channel. A null \a gains disables correction.
	 *
	 * Values are fixed point with \a one representing unity, matching the
	 * convention of the tuning data they typically come from.
	 */
	struct ShadingMap {
		const uint16_t *gains[4];
		unsigned int width;
		unsigned int height;
		uint16_t one;
	};

	/**
	 * \param[in] pattern Channel at each of the 16 cell positions, row major
	 * \param[in] blackLevel Sensor pedestal, subtracted before any gain
	 * \param[in] bitDepth Significant bits of the raw format, e.g. 10
	 *
	 * \a bitDepth is not cosmetic. The CPU debayer indexes 256-entry lookup
	 * tables with the raw value shifted down to 8 bits, so a value above the
	 * format's full scale indexes out of bounds. Shading gains reach 3.5x on
	 * this hardware, which is comfortably enough to get there, so the output
	 * is clamped to full scale rather than to the container.
	 */
	RgbIrToBayer(const Channel pattern[16], uint16_t blackLevel,
		     unsigned int bitDepth = 10);

	/**
	 * \brief Convert one frame
	 * \param[in] src 16-bit input, \a srcStride bytes per line
	 * \param[in] srcWidth Input width, must be a multiple of 4
	 * \param[in] srcHeight Input height, must be a multiple of 4
	 * \param[out] dst 16-bit output, half the input dimensions
	 * \param[in] shading Optional per-channel gain maps
	 *
	 * The output mosaic is GRBG: green at (0,0), red at (0,1), blue at
	 * (1,0), green at (1,1).
	 *
	 * \return 0 on success, -EINVAL if the dimensions are not multiples of 4
	 */
	int convert(const uint8_t *src, unsigned int srcWidth,
		    unsigned int srcHeight, unsigned int srcStride,
		    uint16_t *dst, unsigned int dstStride,
		    Order order = Order::GRBG,
		    const ShadingMap *shading = nullptr) const;

	/**
	 * \brief Convert in place of the input, keeping its dimensions
	 *
	 * Writes each 4x4 cell's values into four identical 2x2 GRBG cells, so
	 * the result is a valid Bayer image at the *input* resolution carrying
	 * half-resolution detail.
	 *
	 * This exists so the conversion can be dropped in ahead of an existing
	 * debayer without renegotiating any buffer size. Downstream sees the
	 * dimensions it already expects. Detail is that of the half-size
	 * output, which for a pipeline that scales down to 720p anyway is not
	 * visible; prefer convert() where the size change can be accommodated.
	 */
	int convertSameSize(const uint8_t *src, unsigned int srcWidth,
			    unsigned int srcHeight, unsigned int srcStride,
			    uint16_t *dst, unsigned int dstStride, Order order,
			    const ShadingMap *shading = nullptr) const;

	/**
	 * \brief Convert to half size, keeping green's spatial detail
	 *
	 * Same geometry and cost as convert(), but sharper. convert() averages
	 * all eight green samples in the 4x4 cell into ONE value and writes it
	 * to both green slots of the output quad, so luma is flat across the
	 * cell - the output is effectively 4x4 binned when the geometry only
	 * calls for 2x.
	 *
	 * The mosaic makes better available for free. Split the cell into four
	 * 2x2 quadrants and each holds exactly two greens, so the quad's two
	 * green slots can carry the top-left and bottom-right quadrant means
	 * instead of one number twice. Green sits at the same density as it
	 * does in Bayer, so this is real detail, not interpolation.
	 *
	 * Chroma stays per-cell: red and blue are only 2 of 16 positions each,
	 * and a 2x2 output quad has just one slot for each, so there is nothing
	 * to gain there. Luma is what the eye reads for sharpness anyway.
	 */
	int convertSharp(const uint8_t *src, unsigned int srcWidth,
			 unsigned int srcHeight, unsigned int srcStride,
			 uint16_t *dst, unsigned int dstStride,
			 Order order = Order::GRBG,
			 const ShadingMap *shading = nullptr) const;

private:
	/* Shared per-cell work: gather, average, shade, re-add the pedestal. */
	void cellValues(const uint8_t *lines[4], unsigned int cx,
			unsigned int cols, unsigned int cy, unsigned int rows,
			const ShadingMap *shading,
			uint16_t &G, uint16_t &R, uint16_t &B) const;

	/*
	 * As cellValues(), but green is returned per 2x2 quadrant of the cell,
	 * in raster order (top-left, top-right, bottom-left, bottom-right).
	 */
	void cellValuesSharp(const uint8_t *lines[4], unsigned int cx,
			     unsigned int cols, unsigned int cy,
			     unsigned int rows, const ShadingMap *shading,
			     uint16_t G[4], uint16_t &R, uint16_t &B) const;

	/* Positions within the cell holding each channel, and how many. */
	uint8_t positions_[4][8];
	uint8_t counts_[4];
	float sharpness_ = 1.0f;
	unsigned int activeY0_ = 0;
	unsigned int activeY1_ = 0;
	uint16_t blackLevel_;
	uint16_t maxValue_;
	float irSubtract_ = 0.0f;

public:
	/**
	 * \brief Set how much of the infrared plane to subtract from R, G and B
	 * \param[in] k Coefficient, 0 disables
	 *
	 * Every colour photosite on this sensor also responds to near-infrared,
	 * so the colour channels carry an IR pedestal that desaturates them.
	 * Subtracting k times the cell's IR average removes it.
	 *
	 * The trade is noise. IR is by far the weakest channel here - of order
	 * 9 counts against green's 98 - so subtracting it adds its noise to all
	 * three colour channels, and the penalty scales with k. Judged by eye
	 * on this hardware, k=1.0 is visibly cleaner than k=2.0 while k=2.0 is
	 * the more colour-accurate; saturation applied afterwards buys chroma
	 * without that noise cost, so prefer a low k with more saturation.
	 */
	void setIrSubtract(float k) { irSubtract_ = k; }

	/**
	 * \brief How much intra-cell green detail convertSharp() restores
	 *
	 * 0 makes convertSharp() identical to convert(): every output green is
	 * the mean of all eight in the cell, which is the quietest option.
	 * 1 uses the 2x2 quadrant mean, which is the sharpest.
	 *
	 * This is a resolution-for-noise trade and NOT a free win. Measured on
	 * a real frame: 1 gives 1.49x the vertical detail but 1.43x the noise,
	 * leaving detail-to-noise essentially unchanged at 1.04x. Averaging two
	 * samples instead of eight can only divide read noise by sqrt(2) rather
	 * than sqrt(8). On a low-detail scene the extra grain is what you see;
	 * on a detailed one, the detail is. Hence a knob rather than a default.
	 */
	/**
	 * \brief Restrict conversion to a band of output rows
	 * \param[in] y0 First output row to produce
	 * \param[in] y1 One past the last output row to produce
	 *
	 * The consumer of this conversion crops. On this machine the pre-pass
	 * emits 1296x972 and the debayer then reads a 1280x720 window at
	 * (8,126), so 252 of the 972 rows - 26% - are computed and thrown away.
	 * Converting only the band that is actually read removes that work from
	 * every frame, and the pipeline is CPU bound on one core.
	 *
	 * Rows outside the band are left untouched, so the caller must not read
	 * them. Pass y1 <= y0 to disable and convert everything.
	 */
	void setActiveRows(unsigned int y0, unsigned int y1)
	{
		activeY0_ = y0;
		activeY1_ = y1;
	}

	void setSharpness(float k) { sharpness_ = k < 0.0f ? 0.0f : (k > 1.0f ? 1.0f : k); }
};

} /* namespace libcamera */
