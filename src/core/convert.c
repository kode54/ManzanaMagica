// SPDX-License-Identifier: GPL-2.0-only
#include "magica.h"

void magica_weave_field(const magica_field *f, int parity, uint8_t *y, int y_stride, uint8_t *cbcr, int cbcr_stride)
{
	for (int line = 0; line < f->lines; line++) {
		const uint8_t *s = f->data + (size_t)line * f->stride;
		uint8_t *dy = y + (size_t)(2 * line + parity) * y_stride;
		uint8_t *dc = cbcr + (size_t)(2 * line + parity) * cbcr_stride;

		for (int x = 0; x < f->width / 2; x++, s += 4) {
			dy[2 * x] = s[0];
			dy[2 * x + 1] = s[2];
			dc[2 * x] = s[1];
			dc[2 * x + 1] = s[3];
		}
	}
}
