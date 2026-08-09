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

private:
	/* Shared per-cell work: gather, average, shade, re-add the pedestal. */
	void cellValues(const uint8_t *lines[4], unsigned int cx,
			unsigned int cols, unsigned int cy, unsigned int rows,
			const ShadingMap *shading,
			uint16_t &G, uint16_t &R, uint16_t &B) const;

	/* Positions within the cell holding each channel, and how many. */
	uint8_t positions_[4][8];
	uint8_t counts_[4];
	uint16_t blackLevel_;
	uint16_t maxValue_;
};

} /* namespace libcamera */
