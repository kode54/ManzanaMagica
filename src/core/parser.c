// SPDX-License-Identifier: GPL-2.0-only
/*
 * em28xx isochronous video packet parser.
 *
 * After linux drivers/media/usb/em28xx/em28xx-video.c
 * (process_frame_data_em28xx, em28xx_copy_video), which is
 *  Copyright (C) 2005 Ludovico Cavedon, Markus Rechberger,
 *  Mauro Carvalho Chehab, Sascha Sommer; 2012 Frank Schäfer
 *
 * Every packet begins with a 4-byte header:
 *   88 88 88 88   continuation
 *   33 95 xx xx   field start, VBI lines first (VBI capture on)
 *   22 5a xx xx   field start, picture only
 * with bit 0 of the third byte set for the bottom field. A field is then
 * `vbi_lines` rows of raw VBI followed by the active picture, all in
 * YUYV at two bytes per pixel.
 */
#include <stdlib.h>
#include <string.h>

#include "internal.h"

enum { CAP_NONE = -1, CAP_VBI = 1, CAP_VIDEO = 3 };

struct magica_parser {
	int width, field_lines, stride;
	int vbi_size;		/* bytes of VBI before the picture */
	uint8_t *buf;		/* one field */
	int field_size;
	int pos;		/* bytes of picture received */
	int vbi_read;
	int state;
	int top;
	int emitted;		/* this field already went out */
	uint64_t t_start;
	uint32_t seq;
	uint32_t fields, short_fields;
	magica_field_cb cb;
	void *ctx;
};

magica_parser *magica_parser_new(int width, int height, int vbi_lines, magica_field_cb cb, void *ctx)
{
	magica_parser *p = calloc(1, sizeof(*p));

	if (!p)
		return NULL;
	p->width = width;
	p->field_lines = height / 2;
	p->stride = width * 2;
	p->vbi_size = vbi_lines * width;	/* 8-bit samples, one per pixel clock */
	p->field_size = p->stride * p->field_lines;
	p->buf = calloc(1, p->field_size);
	if (!p->buf) {
		free(p);
		return NULL;
	}
	p->state = CAP_NONE;
	p->emitted = 1;
	p->cb = cb;
	p->ctx = ctx;
	return p;
}

void magica_parser_free(magica_parser *p)
{
	if (!p)
		return;
	free(p->buf);
	free(p);
}

void magica_parser_counters(magica_parser *p, uint32_t *fields, uint32_t *short_fields)
{
	if (fields)
		*fields = p->fields;
	if (short_fields)
		*short_fields = p->short_fields;
}

/* The capture window starts 2 lines down, so fields end a couple of lines early */
#define SLACK_LINES 4

static void emit(magica_parser *p)
{
	int got = p->pos / p->stride;

	/* repeat the last whole line into rows that never arrived */
	if (got > 0 && got < p->field_lines)
		for (int y = got; y < p->field_lines; y++)
			memcpy(p->buf + (size_t)y * p->stride, p->buf + (size_t)(got - 1) * p->stride, p->stride);

	magica_field f = {
		.data = p->buf,
		.width = p->width,
		.lines = p->field_lines,
		.stride = p->stride,
		.top = p->top,
		.complete = p->pos >= p->field_size - SLACK_LINES * p->stride,
		.seq = p->seq++,
		.time_ns = p->t_start,
	};

	p->emitted = 1;
	p->fields++;
	if (!f.complete)
		p->short_fields++;
	if (p->cb)
		p->cb(p->ctx, &f);
}

/* A new field begins: push out the last one if it never filled up */
static void field_start(magica_parser *p, int top, int with_vbi, uint64_t t)
{
	/* less than a quarter of a field is noise from a restart, not a picture */
	if (!p->emitted) {
		mg_log(p->fields < 4 ? 2 : 3, "field %u cut short: %d of %d bytes (vbi %d)", p->seq, p->pos,
		       p->field_size, p->vbi_read);
		if (p->pos >= p->field_size / 4)
			emit(p);
	}
	p->top = top;
	p->pos = 0;
	p->vbi_read = 0;
	p->emitted = 0;
	p->t_start = t;
	p->state = with_vbi ? CAP_VBI : CAP_VIDEO;
}

void magica_parser_feed(magica_parser *p, const uint8_t *pkt, int len, uint64_t time_ns)
{
	if (len >= 4) {
		if (pkt[0] == 0x88 && pkt[1] == 0x88 && pkt[2] == 0x88 && pkt[3] == 0x88) {
			pkt += 4;
			len -= 4;
		} else if (pkt[0] == 0x33 && pkt[1] == 0x95) {
			field_start(p, !(pkt[2] & 1), 1, time_ns);
			pkt += 4;
			len -= 4;
		} else if (pkt[0] == 0x22 && pkt[1] == 0x5a) {
			field_start(p, !(pkt[2] & 1), 0, time_ns);
			pkt += 4;
			len -= 4;
		}
	}

	if (p->state == CAP_VBI) {
		int n = p->vbi_size - p->vbi_read;

		if (n > len)
			n = len;
		p->vbi_read += n;
		pkt += n;
		len -= n;
		if (p->vbi_read >= p->vbi_size)
			p->state = CAP_VIDEO;
	}

	if (p->state != CAP_VIDEO || len <= 0 || p->emitted)
		return;

	int n = p->field_size - p->pos;

	if (n > len)
		n = len;
	memcpy(p->buf + p->pos, pkt, n);
	p->pos += n;
	/* deliver as soon as the picture is in, not at the next header */
	if (p->pos >= p->field_size)
		emit(p);
}
