# Intel's colour matrices for the OV5678, extracted

`OV5678_0BF501T3_TGL.aiqb` contains record type 25,
`cmc_advanced_color_matrix_correction` - the exact 3x3 colour matrices Intel's
IPU6 pipeline applies to this sensor. This is the "advanced_color_matrices"
record the format doc (`docs/aiqb-format.md`) listed but had not yet decoded.

Extracted with `tools/extract-ccm.py`. The decode is validated, not assumed:
every one of the 525 matrices (7 traditional + 168 per-hue-sector) has each row
summing to 1.0 within 2e-7 - the white-preserving property a CCM must have -
and the rear Bayer camera (`OV8856_0BA801T3_TGL.aiqb`) decodes to the same
structure with its own matrices. A wrong layout would not produce row sums of
1.0 across 525 matrices by accident.

## The seven light sources

Seven illuminants, each with a `traditional` matrix (optimised over all 24 hue
sectors) and 24 `advanced` per-sector matrices. libcamera's simple IPA supports
only the single `traditional` 3x3, so that is what matters here.

| light | CCT | sensor R/G | sensor B/G | traditional CCM (row-major) |
|---|---|---|---|---|
| A (tungsten) | ~2903 K | 0.884 | 0.459 | `1.82640 -0.39456 -0.43184 / -0.27468 1.98980 -0.71513 / -0.52285 -0.79573 2.31858` |
| D65 | ~6381 K | 0.478 | 0.637 | `1.82629 -0.81710 -0.00918 / -0.11632 1.65462 -0.53829 / -0.10662 -0.74934 1.85596` |
| D50 | ~4843 K | 0.543 | 0.579 | `1.81986 -0.77644 -0.04342 / -0.12865 1.56615 -0.43750 / -0.13377 -0.78378 1.91755` |
| F2 (CWF) | ~3659 K | 0.674 | 0.506 | `1.90410 -0.85257 -0.05153 / -0.18757 1.55020 -0.36263 / -0.19263 -0.95175 2.14439` |
| D75 | ~7027 K | 0.454 | 0.673 | `2.04185 -1.06519 0.02334 / -0.11057 1.59411 -0.48353 / -0.12011 -0.65249 1.77261` |
| F11 (TL84) | ~3607 K | 0.709 | 0.517 | `1.95618 -0.79671 -0.15947 / -0.22415 1.58846 -0.36431 / -0.26795 -0.87547 2.14342` |
| F4 (warm white) | ~2419 K | 1.010 | 0.354 | `1.61178 -0.63769 0.02591 / -0.20537 1.07576 0.12962 / 0.30238 -1.86059 2.55821` |

`sensor R/G, B/G` are Intel's own measured native balance of the sensor per
illuminant - useful cross-checks for AWB work, and they agree with this
project's own measurements (the correct 4x4 reading gave R/G ~0.65, B/G ~0.52,
between the A and D65 values as expected for mixed indoor light).

## Why this matters vs the shipped matrix

The matrix currently shipped (`1.8101 -0.3453 -0.4648 / 0.3076 0.4034 0.2890 /
-0.1110 -0.6389 1.7499`) has an **all-positive green row** with a diagonal
(0.4034) smaller than its off-diagonals. That is not a colour correction - it
averages R, G and B into green, which flattens colour separation. Intel's green
rows are proper CCMs, e.g. D65 `-0.116 1.655 -0.538`: the diagonal dominates
and the negative off-diagonals remove red/blue crosstalk from green. This is
what gives Windows its separation that the shipped matrix gives up.

## How to try it

```sh
# Intel's D65 matrix (sRGB / daylight standard):
sudo tools/install-ccm.sh 1.82629,-0.81710,-0.00918,-0.11632,1.65462,-0.53829,-0.10662,-0.74934,1.85596

# Intel's A matrix (tungsten / warm indoor):
sudo tools/install-ccm.sh 1.82640,-0.39456,-0.43184,-0.27468,1.98980,-0.71513,-0.52285,-0.79573,2.31858

# back to the shipped compromise:
sudo tools/install-ccm.sh 1.8101,-0.3453,-0.4648,0.3076,0.4034,0.2890,-0.1110,-0.6389,1.7499
```

## Caveats

- **These are strong matrices.** Off-diagonals up to -1.06 amplify chroma noise
  more than the shipped compromise (~1.9x worst channel). Intel can afford this
  because its IPU6 denoises in raw before the matrix. Judge against a face under
  real light, and lean on `CHROMA_BLUR` / `DENOISE` (already in the pipeline) if
  chroma grain shows. This is exactly the trade the earlier matrix-fitting work
  measured, now made with Intel's actual answer instead of a least-squares guess.
- **The `ct:` label is physical CCT, not libcamera's AWB estimate.** With a
  single matrix installed `getInterpolated()` returns it regardless of
  temperature, so the label is irrelevant. If several are installed to blend,
  the labels must first be reconciled with what `IPASoftAwb` reports (see
  `tools/solve-ccm.py reported_ct`), or the wrong pair blends.
- **White balance is upstream of the matrix.** These are white-preserving (rows
  sum to 1), so they assume the AWB has already balanced the scene. libcamera's
  grey-world AWB is a weaker approximation of Intel's AWB than the matrix is of
  Intel's matrix - expect the matrix to fix hue/separation while leaving any
  residual white-balance cast to the AWB.
- **Provenance.** These numbers are interoperability facts about this camera
  module, the same category as the lens-shading tables already extracted by
  `tools/extract-lens-shading.py`. The `.aiqb` files themselves stay out of the
  repo.
