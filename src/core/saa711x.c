// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Philips SAA7113 (and GM7113C / CJC7113 clones) video decoder.
 *
 * Ported from linux drivers/media/i2c/saa7115.c, which is
 *  Copyright (C) 2005 Mauro Carvalho Chehab <mchehab@kernel.org>
 *  Copyright (C) 2005-2006 Hans Verkuil <hverkuil@kernel.org>
 *  and others (see the Linux file), based on saa7114/saa7111 drivers by
 *  Maxim Yevtyushkin, Dave Perks, Gillem, Rolf Schmidt and Sam Lantinga.
 */
#include <stdio.h>
#include <string.h>

#include "em28xx-reg.h"
#include "internal.h"

enum { SAA7113 = 1, GM7113C = 2 };

/* SAA7113 init codes (saa7113_init) */
static const uint8_t saa7113_init[] = {
	0x01, 0x08,
	0x02, 0xc2,
	0x03, 0x30,
	0x04, 0x00,
	0x05, 0x00,
	0x06, 0x89,	/* illegal value -119, min. value = -108 (0x94) */
	0x07, 0x0d,
	0x08, 0x88,	/* not datasheet default: HTC = VTR mode, should be 0x98 */
	0x09, 0x01,
	0x0a, 0x80,
	0x0b, 0x47,
	0x0c, 0x40,
	0x0d, 0x00,
	0x0e, 0x01,
	0x0f, 0x2a,
	0x10, 0x08,	/* not datasheet default: VRLN enabled, should be 0x00 */
	0x11, 0x0c,
	0x12, 0x07,	/* not datasheet default, should be 0x01 */
	0x13, 0x00,
	0x15, 0x00,
	0x16, 0x00,
	0x17, 0x00,
	0x00, 0x00
};

/* GM7113C init codes, from its datasheet (gm7113c_init) */
static const uint8_t gm7113c_init[] = {
	0x01, 0x08,
	0x02, 0xc0,
	0x03, 0x33,
	0x04, 0x00,
	0x05, 0x00,
	0x06, 0xe9,
	0x07, 0x0d,
	0x08, 0x98,
	0x09, 0x01,
	0x0a, 0x80,
	0x0b, 0x47,
	0x0c, 0x40,
	0x0d, 0x00,
	0x0e, 0x01,
	0x0f, 0x2a,
	0x10, 0x00,
	0x11, 0x0c,
	0x12, 0x01,
	0x13, 0x00,
	0x15, 0x00,
	0x16, 0x00,
	0x17, 0x00,
	0x00, 0x00
};

/* The SAA7113's share of saa7115_cfg_60hz_video / saa7115_cfg_50hz_video */
static const uint8_t saa7113_60hz[] = {
	0x15, 0x03,	/* VGATE start, FID change */
	0x16, 0x11,	/* VGATE stop */
	0x17, 0x9c,	/* misc VGATE, MSBs */
	0x08, 0x68,	/* sync control: 60 Hz */
	0x0e, 0x07,
	0x5a, 0x06,	/* V offset for the slicer: ITU 656 line counting */
	0x00, 0x00
};

static const uint8_t saa7113_50hz[] = {
	0x15, 0x37,
	0x16, 0x16,
	0x17, 0x99,
	0x08, 0x28,	/* sync control: 50 Hz */
	0x0e, 0x07,
	0x5a, 0x03,
	0x00, 0x00
};

static int saa_write(struct magica_dev *d, uint8_t reg, uint8_t val)
{
	uint8_t b[2] = { reg, val };

	return em_i2c_write(d, d->saa_addr, b, 2, 1);
}

static int saa_read(struct magica_dev *d, uint8_t reg)
{
	uint8_t v;
	int ret = em_i2c_write(d, d->saa_addr, &reg, 1, 0);

	if (ret < 0)
		return ret;
	ret = em_i2c_read(d, d->saa_addr, &v, 1);
	return ret < 0 ? ret : v;
}

static int has_reg(struct magica_dev *d, uint8_t reg)
{
	if (d->saa_ident == GM7113C)
		return reg != 0x14 && (reg < 0x18 || reg > 0x1e) && reg < 0x20;
	return reg != 0x14 && (reg < 0x18 || reg > 0x1e) && (reg < 0x20 || reg > 0x3f) &&
	       reg != 0x5c && reg != 0x5d && reg != 0x5f && reg < 0x63;
}

static int saa_writeregs(struct magica_dev *d, const uint8_t *regs)
{
	for (; regs[0]; regs += 2) {
		if (!has_reg(d, regs[0]))
			continue;
		int ret = saa_write(d, regs[0], regs[1]);

		if (ret < 0)
			return ret;
	}
	return 0;
}

static int detect(struct magica_dev *d, char name[17])
{
	uint8_t ver[16];

	for (int i = 0; i < 16; i++) {
		if (saa_write(d, SAA_R00_CHIP_VERSION, i) < 0)
			return MAGICA_ENODEV;
		int v = saa_read(d, SAA_R00_CHIP_VERSION);

		if (v < 0)
			return MAGICA_ENODEV;
		ver[i] = v;
		name[i] = "0123456789abcdef"[v & 0x0f];
	}
	name[16] = 0;
	mg_dbg("decoder at 0x%02x reports %s", d->saa_addr, name);

	if (!memcmp(name + 1, "f711", 4)) {
		if (name[5] == '3')
			return SAA7113;
		mg_err("saa711%c isn't supported yet", name[5]);
		return MAGICA_EUNSUPPORTED;
	}
	if (!memcmp(name, "0000", 4))
		return GM7113C;
	if (!memcmp(name, "1111111111111111", 16))
		return SAA7113;	/* CJC7113 */
	(void)ver;
	return MAGICA_ENODEV;
}

int saa_probe(struct magica_dev *d)
{
	static const uint8_t addrs[] = { 0x4a, 0x48 };
	char name[17];
	int ident = MAGICA_ENODEV;

	for (size_t i = 0; i < sizeof(addrs) && ident < 0; i++) {
		d->saa_addr = addrs[i];
		ident = detect(d, name);
	}
	if (ident < 0) {
		mg_err("no SAA711x-compatible decoder answered on I2C");
		return ident == MAGICA_ENODEV ? MAGICA_EUNSUPPORTED : ident;
	}
	d->saa_ident = ident;
	if (ident == GM7113C)
		snprintf(d->info.decoder, sizeof(d->info.decoder), "gm7113c");
	else if (name[0] == '1' && name[1] == '1')
		snprintf(d->info.decoder, sizeof(d->info.decoder), "cjc7113");
	else
		snprintf(d->info.decoder, sizeof(d->info.decoder), "saa7113");
	mg_info("decoder %s at 0x%02x", d->info.decoder, d->saa_addr);

	int ret = saa_writeregs(d, ident == GM7113C ? gm7113c_init : saa7113_init);

	if (ret < 0)
		return ret;
	/* picture defaults, chroma AGC on */
	return saa_set_picture(d, 128, 64, 64, 0);
}

int saa_set_std(struct magica_dev *d, magica_std std)
{
	int ret, is50 = magica_std_is_50hz(std);

	if (d->saa_ident == GM7113C) {
		int r = saa_read(d, SAA_R08_SYNC_CNTL);

		if (r < 0)
			return r;
		r &= ~(0x40 | 0x80);	/* FSEL, AUFD */
		if (!is50)
			r |= 0x40;
		ret = saa_write(d, SAA_R08_SYNC_CNTL, r);
	} else {
		ret = saa_writeregs(d, is50 ? saa7113_50hz : saa7113_60hz);
	}
	if (ret < 0)
		return ret;

	/*
	 * Register 0E bits 6-4, colour standard:
	 *      50 Hz / 625 lines           60 Hz / 525 lines
	 * 000  PAL BGDHI (4.43 MHz)        NTSC M (3.58 MHz)
	 * 001  NTSC 4.43 (50 Hz)           PAL 4.43 (60 Hz)
	 * 010  Combination-PAL N (3.58)    NTSC 4.43 (60 Hz)
	 * 011  NTSC N (3.58 MHz)           PAL M (3.58 MHz)
	 * 100  reserved                    NTSC-Japan (3.58 MHz)
	 * 101  SECAM
	 */
	int r = saa_read(d, SAA_R0E_CHROMA_CNTL_1);

	if (r < 0)
		return r;
	r &= 0x8f;
	switch (std) {
	case MAGICA_STD_PAL_M: r |= 0x30; break;
	case MAGICA_STD_PAL_N: r |= 0x20; break;
	case MAGICA_STD_PAL_60: r |= 0x10; break;
	case MAGICA_STD_NTSC_443: r |= 0x20; break;
	case MAGICA_STD_NTSC_J: r |= 0x40; break;
	case MAGICA_STD_SECAM: r |= 0x50; break;
	default: break;
	}
	return saa_write(d, SAA_R0E_CHROMA_CNTL_1, r);
}

int saa_set_input(struct magica_dev *d, magica_input input)
{
	/* the iGrabber wires composite to AI11 (mode 0) and S-Video to AI12/AI22 (mode 9) */
	int mode = input == MAGICA_INPUT_SVIDEO ? 9 : 0;
	int r = saa_read(d, SAA_R02_INPUT_CNTL_1);

	if (r < 0)
		return r;
	int ret = saa_write(d, SAA_R02_INPUT_CNTL_1, (r & 0xf0) | mode);

	if (ret < 0)
		return ret;
	/* bypass the chroma trap for S-Video */
	r = saa_read(d, SAA_R09_LUMA_CNTL);
	if (r < 0)
		return r;
	return saa_write(d, SAA_R09_LUMA_CNTL, (r & 0x7f) | (input == MAGICA_INPUT_SVIDEO ? 0x80 : 0));
}

int saa_status(struct magica_dev *d)
{
	int st = saa_read(d, SAA_R1F_STATUS_BYTE_2);

	mg_dbg("decoder status 0x%02x", st);
	return st;
}

int saa_set_picture(struct magica_dev *d, int brightness, int contrast, int saturation, int hue)
{
	if (brightness < 0 || brightness > 255 || contrast < 0 || contrast > 127 ||
	    saturation < 0 || saturation > 127 || hue < -128 || hue > 127)
		return MAGICA_EINVAL;
	int ret;

	if ((ret = saa_write(d, SAA_R0A_LUMA_BRIGHT_CNTL, brightness)) < 0 ||
	    (ret = saa_write(d, SAA_R0B_LUMA_CONTRAST_CNTL, contrast)) < 0 ||
	    (ret = saa_write(d, SAA_R0C_CHROMA_SAT_CNTL, saturation)) < 0 ||
	    (ret = saa_write(d, SAA_R0D_CHROMA_HUE_CNTL, (uint8_t)hue)) < 0)
		return ret;
	/* chroma AGC on, gain 40 */
	return saa_write(d, SAA_R0F_CHROMA_GAIN_CNTL, 40);
}
