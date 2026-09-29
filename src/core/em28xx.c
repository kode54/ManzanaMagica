// SPDX-License-Identifier: GPL-2.0-only
/*
 * em28xx bridge over libusb: registers, I2C, AC'97, isochronous streaming.
 *
 * Ported from linux drivers/media/usb/em28xx (em28xx-core.c, em28xx-i2c.c,
 * em28xx-video.c, em28xx-audio.c, em28xx-cards.c), which is
 *  Copyright (C) 2005 Ludovico Cavedon <cavedon@sssup.it>
 *		      Markus Rechberger <mrechberger@gmail.com>
 *		      Mauro Carvalho Chehab <mchehab@kernel.org>
 *		      Sascha Sommer <saschasommer@freenet.de>
 *  Copyright (C) 2012 Frank Schäfer <fschaefer.oss@googlemail.com>
 */
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <libusb.h>

#include "em28xx-reg.h"
#include "internal.h"

#define CTRL_TIMEOUT_MS 1000
#define VENDOR_IN (LIBUSB_ENDPOINT_IN | LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_DEVICE)
#define VENDOR_OUT (LIBUSB_ENDPOINT_OUT | LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_DEVICE)

#define EP_VIDEO 0x82
#define EP_AUDIO 0x83

/* The em28xx boards we know how to wire up */
static const struct board {
	uint16_t vid, pid;
	const char *name;
} boards[] = {
	/* Empia EM2860, Philips SAA7113, Empia EMP202, no tuner */
	{ 0x1f4d, 0x1abe, "MyGica iGrabber" },
	/* the chip's default IDs, used by many no-name EM2860 grabbers */
	{ 0xeb1a, 0x2860, "EM2860 capture device" },
	{ 0xeb1a, 0x2861, "EM2861 capture device" },
};

static void msleep(int ms)
{
	usleep(ms * 1000);
}

static uint64_t now_ns(void)
{
	return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static int usb_err(struct magica_dev *d, int ret)
{
	if (ret == LIBUSB_ERROR_NO_DEVICE) {
		d->gone = true;
		return MAGICA_EGONE;
	}
	return MAGICA_EIO;
}

/* ---- registers ---- */

int em_read_len(struct magica_dev *d, uint8_t req, uint16_t reg, uint8_t *buf, int len)
{
	if (d->gone)
		return MAGICA_EGONE;
	int ret = libusb_control_transfer(d->h, VENDOR_IN, req, 0, reg, buf, len, CTRL_TIMEOUT_MS);

	if (ret < 0) {
		mg_dbg("read req %d reg 0x%02x failed: %s", req, reg, libusb_error_name(ret));
		return usb_err(d, ret);
	}
	if (mg_log_enabled(3))
		mg_log(3, "IN  req %d reg 0x%02x len %d -> %02x%s", req, reg, len, len ? buf[0] : 0,
		       len > 1 ? " …" : "");
	return ret;
}

int em_read(struct magica_dev *d, uint16_t reg)
{
	uint8_t v;
	int ret = em_read_len(d, 0, reg, &v, 1);

	if (ret < 0)
		return ret;
	return ret == 1 ? v : MAGICA_EIO;
}

int em_write_len(struct magica_dev *d, uint8_t req, uint16_t reg, const uint8_t *buf, int len)
{
	if (d->gone)
		return MAGICA_EGONE;
	int ret = libusb_control_transfer(d->h, VENDOR_OUT, req, 0, reg, (uint8_t *)buf, len, CTRL_TIMEOUT_MS);

	if (mg_log_enabled(3))
		mg_log(3, "OUT req %d reg 0x%02x len %d <- %02x%s%s", req, reg, len, buf[0], len > 1 ? " …" : "",
		       ret < 0 ? " FAILED" : "");
	if (ret < 0) {
		mg_dbg("write req %d reg 0x%02x failed: %s", req, reg, libusb_error_name(ret));
		return usb_err(d, ret);
	}
	/* the em2860 needs a moment after every write */
	if (d->wait_after_write_ms)
		msleep(d->wait_after_write_ms);
	return ret;
}

int em_write(struct magica_dev *d, uint16_t reg, uint8_t val)
{
	int ret = em_write_len(d, 0, reg, &val, 1);

	return ret < 0 ? ret : 0;
}

int em_write_bits(struct magica_dev *d, uint16_t reg, uint8_t val, uint8_t mask)
{
	int old = em_read(d, reg);

	if (old < 0)
		return old;
	return em_write(d, reg, (uint8_t)((old & ~mask) | (val & mask)));
}

/* ---- I2C (addresses are 8-bit, as on the wire) ---- */

static int i2c_status(struct magica_dev *d, uint8_t addr, int writing)
{
	/* 0 = done, 0x10 = no ACK, 0x02/0x04 = clock stretching timeout */
	for (int tries = 0; tries < 20; tries++) {
		int st = em_read(d, EM28XX_R05_I2C_STATUS);

		if (st < 0)
			return st;
		if (st == 0)
			return 0;
		if (st == 0x10) {
			mg_dbg("i2c 0x%02x: no ACK on %s", addr, writing ? "write" : "read");
			return MAGICA_EIO;
		}
		if (!writing)
			return MAGICA_EIO;
		msleep(5);
	}
	mg_dbg("i2c 0x%02x: timed out", addr);
	return MAGICA_EIO;
}

int em_i2c_write(struct magica_dev *d, uint8_t addr, const uint8_t *buf, int len, int stop)
{
	int ret = em_write_len(d, stop ? 2 : 3, addr, buf, len);

	if (ret < 0)
		return ret;
	if (ret != len)
		return MAGICA_EIO;
	return i2c_status(d, addr, 1);
}

int em_i2c_read(struct magica_dev *d, uint8_t addr, uint8_t *buf, int len)
{
	int ret = em_read_len(d, 2, addr, buf, len);

	if (ret < 0)
		return ret;
	return i2c_status(d, addr, 0);
}

/* ---- AC'97 ---- */

static int ac97_wait(struct magica_dev *d)
{
	for (int i = 0; i < 10; i++) {
		int st = em_read(d, EM28XX_R43_AC97BUSY);

		if (st < 0)
			return st;
		if (!(st & 1))
			return 0;
		msleep(5);
	}
	mg_dbg("AC97 still busy");
	return MAGICA_EIO;
}

int em_ac97_read(struct magica_dev *d, uint8_t reg)
{
	uint8_t addr = (reg & 0x7f) | 0x80, v[2];
	int ret = ac97_wait(d);

	if (ret < 0)
		return ret;
	if ((ret = em_write(d, EM28XX_R42_AC97ADDR, addr)) < 0)
		return ret;
	if ((ret = em_read_len(d, 0, EM28XX_R40_AC97LSB, v, 2)) < 0)
		return ret;
	return v[0] | v[1] << 8;
}

int em_ac97_write(struct magica_dev *d, uint8_t reg, uint16_t val)
{
	uint8_t v[2] = { val & 0xff, val >> 8 };
	int ret = ac97_wait(d);

	if (ret < 0)
		return ret;
	if ((ret = em_write_len(d, 0, EM28XX_R40_AC97LSB, v, 2)) < 0)
		return ret;
	return em_write(d, EM28XX_R42_AC97ADDR, reg & 0x7f);
}

/* ---- audio (em28xx_audio_setup / em28xx_audio_analog_set) ---- */

static const uint8_t ac97_inputs[] = {
	AC97_VIDEO, AC97_LINE, AC97_PHONE, AC97_MIC, AC97_CD, AC97_AUX, AC97_PCM,
};
static const uint8_t ac97_outputs[] = {
	AC97_MASTER, AC97_HEADPHONE, AC97_MASTER_MONO, AC97_CENTER_LFE_MASTER, AC97_SURROUND_MASTER,
};

static int audio_analog_set(struct magica_dev *d)
{
	int ret;

	if (d->ac97) {
		for (size_t i = 0; i < sizeof(ac97_outputs); i++)
			em_ac97_write(d, ac97_outputs[i], 0x8000);
	}

	ret = em_write(d, EM28XX_R0F_XCLK, (EM28XX_XCLK_DEFAULT & 0x7f) | (d->mute ? 0 : EM28XX_XCLK_AUDIO_UNMUTE));
	if (ret < 0)
		return ret;
	msleep(10);

	/* both of the iGrabber's inputs take sound from the line input */
	ret = em_write_bits(d, EM28XX_R0E_AUDIOSRC, EM28XX_AUDIO_SRC_LINE, 0xc0);
	if (ret < 0)
		return ret;
	msleep(10);

	if (!d->ac97)
		return 0;

	for (size_t i = 0; i < sizeof(ac97_inputs); i++)
		em_ac97_write(d, ac97_inputs[i], ac97_inputs[i] == AC97_LINE ? 0x0808 : 0x8000);

	em_ac97_write(d, AC97_POWERDOWN, 0x4200);
	em_ac97_write(d, AC97_EXTENDED_STATUS, 0x0031);
	em_ac97_write(d, AC97_PCM_LR_ADC_RATE, 0xbb80);	/* 48000 Hz */

	int vol = (0x1f - d->volume) | (0x1f - d->volume) << 8;

	if (d->mute)
		vol |= 0x8000;
	return em_ac97_write(d, AC97_MASTER, vol);
}

static int audio_setup(struct magica_dev *d)
{
	int cfg = em_read(d, EM28XX_R00_CHIPCFG);

	mg_info("chip config 0x%02x", cfg);
	if (cfg < 0)
		return cfg;

	if ((cfg & EM28XX_CHIPCFG_AUDIOMASK) == 0) {
		snprintf(d->info.audio, sizeof(d->info.audio), "none");
		d->ac97 = 0;
		d->info.has_audio = 0;
		return 0;
	}
	if ((cfg & EM28XX_CHIPCFG_AUDIOMASK) != EM28XX_CHIPCFG_AC97) {
		snprintf(d->info.audio, sizeof(d->info.audio), "I2S");
		d->ac97 = 0;
		return audio_analog_set(d);
	}

	int vid1 = em_ac97_read(d, AC97_VENDOR_ID1);

	if (vid1 < 0) {
		mg_info("AC97 chip type couldn't be determined");
		snprintf(d->info.audio, sizeof(d->info.audio), "none");
		d->ac97 = 0;
		d->info.has_audio = 0;
		return 0;
	}
	int vid2 = em_ac97_read(d, AC97_VENDOR_ID2);
	int feat = em_ac97_read(d, AC97_RESET);
	uint32_t vid = (uint32_t)vid1 << 16 | (uint16_t)vid2;

	mg_info("AC97 vendor ID 0x%08x, features 0x%04x", vid, feat);
	if ((vid == 0xffffffff || vid == 0x83847650) && feat == 0x6a90) {
		d->ac97 = 1;
		snprintf(d->info.audio, sizeof(d->info.audio), "EMP202 AC'97");
	} else {
		d->ac97 = 2;
		snprintf(d->info.audio, sizeof(d->info.audio), "AC'97 %08x", vid);
	}
	return audio_analog_set(d);
}

int magica_set_audio(magica_dev *d, int volume, int mute)
{
	if (volume < 0 || volume > 0x1f)
		return MAGICA_EINVAL;
	pthread_mutex_lock(&d->ctrl);
	d->volume = volume;
	d->mute = !!mute;
	int ret = audio_analog_set(d);
	pthread_mutex_unlock(&d->ctrl);
	return ret < 0 ? ret : 0;
}

/* ---- video format (em28xx_resolution_set) ---- */

static int vbi_lines(struct magica_dev *d)
{
	return magica_std_is_50hz(d->std) ? 18 : 12;
}

static int resolution_set(struct magica_dev *d)
{
	int w = d->width, h = d->height;

	/* YUYV out; the decoder hands over CbYCrY as ITU-R BT.656 */
	em_write(d, EM28XX_R27_OUTFMT, EM28XX_OUTFMT_YUV422_Y0UY1V | 0x20);
	em_write(d, EM28XX_R10_VINMODE, EM28XX_VINMODE_YUV422_CbYCrY);

	/* raw VBI is on, as Linux has it for the em2860: lines 20/21 then stay out of the picture */
	em_write(d, EM28XX_R34_VBI_START_H, 0x00);
	em_write(d, EM28XX_R36_VBI_WIDTH, 720 / 4);
	em_write(d, EM28XX_R37_VBI_HEIGHT, vbi_lines(d));
	em_write(d, EM28XX_R35_VBI_START_V, magica_std_is_50hz(d->std) ? 0x07 : 0x09);
	em_write(d, EM28XX_R11_VINCTRL,
		 EM28XX_VINCTRL_INTERLACED | EM28XX_VINCTRL_CCIR656_ENABLE | EM28XX_VINCTRL_VBI_RAW);

	/* accumulator */
	em_write(d, EM28XX_R28_XMIN, 1);
	em_write(d, EM28XX_R29_XMAX, (w - 4) >> 2);
	em_write(d, EM28XX_R2A_YMIN, 1);
	em_write(d, EM28XX_R2B_YMAX, (h - 4) >> 2);

	/* capture area */
	em_write(d, EM28XX_R1C_HSTART, 0);
	em_write(d, EM28XX_R1D_VSTART, 2);
	em_write(d, EM28XX_R1E_CWIDTH, w >> 2);
	em_write(d, EM28XX_R1F_CHEIGHT, h >> 2);
	em_write(d, EM28XX_R1B_OFLOW, (h >> 9 & 0x02) | (w >> 10 & 0x01));

	/* no scaling */
	static const uint8_t zero[2];

	em_write_len(d, 0, EM28XX_R30_HSCALELOW, zero, 2);
	em_write_len(d, 0, EM28XX_R32_VSCALELOW, zero, 2);
	return em_write(d, EM28XX_R26_COMPR, 0x00);
}

static void colorlevels_default(struct magica_dev *d)
{
	em_write(d, EM28XX_R20_YGAIN, 0x10);
	em_write(d, EM28XX_R21_YOFFSET, 0x00);
	em_write(d, EM28XX_R22_UVGAIN, 0x10);
	em_write(d, EM28XX_R23_UOFFSET, 0x00);
	em_write(d, EM28XX_R24_VOFFSET, 0x00);
	em_write(d, EM28XX_R25_SHARPNESS, 0x00);
	em_write(d, EM28XX_R14_GAMMA, 0x20);
	em_write(d, EM28XX_R15_RGAIN, 0x20);
	em_write(d, EM28XX_R16_GGAIN, 0x20);
	em_write(d, EM28XX_R17_BGAIN, 0x20);
	em_write(d, EM28XX_R18_ROFFSET, 0x00);
	em_write(d, EM28XX_R19_GOFFSET, 0x00);
	em_write(d, EM28XX_R1A_BOFFSET, 0x00);
}

int magica_set_std(magica_dev *d, magica_std std)
{
	if (std < MAGICA_STD_NTSC_M || std > MAGICA_STD_SECAM)
		return MAGICA_EINVAL;
	if (d->running)
		return MAGICA_EBUSY;
	pthread_mutex_lock(&d->ctrl);
	d->std = std;
	d->width = 720;
	d->height = magica_std_is_50hz(std) ? 576 : 480;
	int ret = resolution_set(d);

	if (ret >= 0)
		ret = saa_set_std(d, std);
	pthread_mutex_unlock(&d->ctrl);
	return ret < 0 ? ret : 0;
}

int magica_set_input(magica_dev *d, magica_input input)
{
	if (input != MAGICA_INPUT_COMPOSITE && input != MAGICA_INPUT_SVIDEO)
		return MAGICA_EINVAL;
	pthread_mutex_lock(&d->ctrl);
	int ret = saa_set_input(d, input);

	if (ret >= 0) {
		d->input = input;
		ret = audio_analog_set(d);
	}
	pthread_mutex_unlock(&d->ctrl);
	return ret < 0 ? ret : 0;
}

int magica_set_picture(magica_dev *d, int brightness, int contrast, int saturation, int hue)
{
	pthread_mutex_lock(&d->ctrl);
	int ret = saa_set_picture(d, brightness, contrast, saturation, hue);
	pthread_mutex_unlock(&d->ctrl);
	return ret;
}

int magica_detect_50hz(magica_dev *d)
{
	pthread_mutex_lock(&d->ctrl);
	int st = saa_status(d);
	pthread_mutex_unlock(&d->ctrl);
	if (st < 0)
		return st;
	return !(st & SAA7113_STATUS_FIDT);
}

int magica_width(magica_dev *d)
{
	return d->width;
}

int magica_height(magica_dev *d)
{
	return d->height;
}

int magica_status_get(magica_dev *d, magica_status *s)
{
	memset(s, 0, sizeof(*s));
	s->streaming = d->running;
	s->gone = d->gone;
	s->packet_errors = d->packet_errors;
	s->audio_frames = d->audio_frames;
	if (d->parser)
		magica_parser_counters(d->parser, &s->fields, &s->short_fields);
	if (d->gone)
		return MAGICA_EGONE;

	pthread_mutex_lock(&d->ctrl);
	int st = saa_status(d);
	pthread_mutex_unlock(&d->ctrl);
	if (st < 0)
		return st;
	s->locked = !(st & SAA7113_STATUS_HLVLN);
	s->is_50hz = !(st & SAA7113_STATUS_FIDT);
	s->color = !!(st & SAA7113_STATUS_RDCAP);
	s->interlaced = !!(st & SAA7113_STATUS_INTL);
	return 0;
}

/* ---- USB layout (em28xx_check_usb_descriptor) ---- */

static int packet_size(const struct libusb_endpoint_descriptor *e)
{
	int w = e->wMaxPacketSize;

	return (w & 0x7ff) * (1 + ((w >> 11) & 3));
}

static int scan_descriptors(struct magica_dev *d, libusb_device *dev)
{
	struct libusb_config_descriptor *cfg;
	int ret = libusb_get_active_config_descriptor(dev, &cfg);

	if (ret < 0)
		return usb_err(d, ret);

	d->ifnum = -1;
	for (int i = 0; i < cfg->bNumInterfaces; i++) {
		const struct libusb_interface *itf = &cfg->interface[i];

		for (int a = 0; a < itf->num_altsetting && a < MG_MAX_ALTS; a++) {
			const struct libusb_interface_descriptor *alt = &itf->altsetting[a];

			if (alt->bInterfaceClass == LIBUSB_CLASS_AUDIO)
				d->info.usb_audio_class = 1;
			for (int k = 0; k < alt->bNumEndpoints; k++) {
				const struct libusb_endpoint_descriptor *e = &alt->endpoint[k];
				int iso = (e->bmAttributes & 3) == LIBUSB_ENDPOINT_TRANSFER_TYPE_ISOCHRONOUS;

				if (!iso)
					continue;
				if (e->bEndpointAddress == EP_VIDEO) {
					d->ifnum = alt->bInterfaceNumber;
					d->num_alt = itf->num_altsetting;
					d->video_pkt[a] = packet_size(e);
				} else if (e->bEndpointAddress == EP_AUDIO) {
					d->audio_pkt[a] = packet_size(e);
					d->audio_interval = e->bInterval;
				}
			}
		}
	}
	libusb_free_config_descriptor(cfg);

	if (d->ifnum < 0) {
		mg_err("no isochronous video endpoint 0x82");
		return MAGICA_EUNSUPPORTED;
	}
	for (int a = 0; a < d->num_alt; a++)
		mg_dbg("alt %d: video %d bytes, audio %d bytes", a, d->video_pkt[a], d->audio_pkt[a]);
	return 0;
}

/* ---- open / close ---- */

static int find_device(struct magica_dev *d, libusb_device **found, const struct board **board)
{
	libusb_device **list;
	ssize_t n = libusb_get_device_list(d->ctx, &list);

	if (n < 0)
		return MAGICA_EIO;
	*found = NULL;
	for (ssize_t i = 0; i < n && !*found; i++) {
		struct libusb_device_descriptor desc;

		if (libusb_get_device_descriptor(list[i], &desc) < 0)
			continue;
		for (size_t b = 0; b < sizeof(boards) / sizeof(boards[0]); b++) {
			if (desc.idVendor == boards[b].vid && desc.idProduct == boards[b].pid) {
				*found = libusb_ref_device(list[i]);
				*board = &boards[b];
				break;
			}
		}
	}
	libusb_free_device_list(list, 1);
	return *found ? 0 : MAGICA_ENODEV;
}

static int init_chip(struct magica_dev *d)
{
	int id = em_read(d, EM28XX_R0A_CHIPID);

	if (id < 0)
		return id;
	d->info.chip_id = id;
	switch (id) {
	case CHIP_ID_EM2860:
		snprintf(d->info.chip, sizeof(d->info.chip), "em2860");
		break;
	case CHIP_ID_EM2820:
		snprintf(d->info.chip, sizeof(d->info.chip), "em2820");
		break;
	case CHIP_ID_EM2840:
		snprintf(d->info.chip, sizeof(d->info.chip), "em2840");
		break;
	default:
		snprintf(d->info.chip, sizeof(d->info.chip), "id %d", id);
		mg_err("em28xx chip id %d isn't supported yet", id);
		return MAGICA_EUNSUPPORTED;
	}
	mg_info("bridge %s", d->info.chip);

	/* em28xx_set_xclk_i2c_speed: 12 MHz XCLK, 100 kHz I2C with clock stretching */
	em_write(d, EM28XX_R0F_XCLK, EM28XX_XCLK_DEFAULT);
	em_write(d, EM28XX_R06_I2C_CLK, EM28XX_I2C_CLK_WAIT_ENABLE | EM28XX_I2C_FREQ_100_KHZ);
	msleep(50);

	int ret = saa_probe(d);

	if (ret < 0)
		return ret;

	d->volume = 0x1f;
	d->mute = 0;
	if ((ret = audio_setup(d)) < 0)
		return ret;

	d->std = MAGICA_STD_NTSC_M;
	d->width = 720;
	d->height = 480;
	if ((ret = resolution_set(d)) < 0)
		return ret;
	if ((ret = saa_set_std(d, d->std)) < 0)
		return ret;
	if ((ret = saa_set_input(d, MAGICA_INPUT_COMPOSITE)) < 0)
		return ret;
	colorlevels_default(d);
	return 0;
}

int magica_open(magica_dev **out, magica_info *info)
{
	struct magica_dev *d = calloc(1, sizeof(*d));
	libusb_device *dev = NULL;
	const struct board *board = NULL;
	int ret;

	*out = NULL;
	if (!d)
		return MAGICA_ENOMEM;
	pthread_mutex_init(&d->ctrl, NULL);
	d->wait_after_write_ms = 5;

	if (libusb_init_context(&d->ctx, NULL, 0) < 0) {
		free(d);
		return MAGICA_EIO;
	}
	if ((ret = find_device(d, &dev, &board)) < 0)
		goto fail;

	struct libusb_device_descriptor desc;

	libusb_get_device_descriptor(dev, &desc);
	d->info.vid = desc.idVendor;
	d->info.pid = desc.idProduct;
	snprintf(d->info.board, sizeof(d->info.board), "%s", board->name);

	ret = libusb_open(dev, &d->h);
	if (ret < 0) {
		mg_err("open %04x:%04x: %s", desc.idVendor, desc.idProduct, libusb_error_name(ret));
		ret = ret == LIBUSB_ERROR_ACCESS || ret == LIBUSB_ERROR_BUSY ? MAGICA_EBUSY : MAGICA_EIO;
		goto fail;
	}
	if ((ret = scan_descriptors(d, dev)) < 0)
		goto fail;

	ret = libusb_claim_interface(d->h, d->ifnum);
	if (ret < 0) {
		mg_err("claim interface %d: %s", d->ifnum, libusb_error_name(ret));
		ret = ret == LIBUSB_ERROR_ACCESS || ret == LIBUSB_ERROR_BUSY ? MAGICA_EBUSY : MAGICA_EIO;
		goto fail;
	}
	/* alt 0 has no bandwidth: register access only until we stream */
	libusb_set_interface_alt_setting(d->h, d->ifnum, 0);

	for (int a = 0; a < d->num_alt; a++)
		if (d->audio_pkt[a])
			d->info.has_audio = 1;

	if ((ret = init_chip(d)) < 0)
		goto fail;

	libusb_unref_device(dev);
	if (info)
		*info = d->info;
	*out = d;
	return 0;

fail:
	if (dev)
		libusb_unref_device(dev);
	if (d->h) {
		libusb_release_interface(d->h, d->ifnum < 0 ? 0 : d->ifnum);
		libusb_close(d->h);
	}
	libusb_exit(d->ctx);
	pthread_mutex_destroy(&d->ctrl);
	free(d);
	return ret;
}

void magica_close(magica_dev *d)
{
	if (!d)
		return;
	magica_stop(d);
	libusb_release_interface(d->h, d->ifnum);
	libusb_close(d->h);
	libusb_exit(d->ctx);
	pthread_mutex_destroy(&d->ctrl);
	free(d);
}

/* ---- streaming ---- */

static void xfer_done(struct magica_dev *d, struct libusb_transfer *t)
{
	if (t->status == LIBUSB_TRANSFER_NO_DEVICE)
		d->gone = true;
	if (d->running && !d->gone && t->status != LIBUSB_TRANSFER_CANCELLED) {
		int ret = libusb_submit_transfer(t);

		if (ret == 0)
			return;
		mg_dbg("resubmit failed: %s", libusb_error_name(ret));
		if (ret == LIBUSB_ERROR_NO_DEVICE)
			d->gone = true;
	}
	d->active_xfers--;
}

static void video_cb(struct libusb_transfer *t)
{
	struct magica_dev *d = t->user_data;
	uint64_t now = now_ns();
	int max = d->video_pkt[d->info.alt];

	if (t->status == LIBUSB_TRANSFER_COMPLETED) {
		for (int i = 0; i < t->num_iso_packets; i++) {
			struct libusb_iso_packet_descriptor *p = &t->iso_packet_desc[i];

			if (p->status != LIBUSB_TRANSFER_COMPLETED) {
				d->packet_errors++;
				continue;
			}
			if (!p->actual_length || (int)p->actual_length > max)
				continue;
			/* 125 µs per microframe, counting back from the completion */
			uint64_t t_pkt = now - (uint64_t)(t->num_iso_packets - 1 - i) * 125000;

			magica_parser_feed(d->parser, libusb_get_iso_packet_buffer_simple(t, i), p->actual_length, t_pkt);
		}
	}
	xfer_done(d, t);
}

static void audio_cb(struct libusb_transfer *t)
{
	struct magica_dev *d = t->user_data;
	uint64_t now = now_ns();

	if (t->status == LIBUSB_TRANSFER_COMPLETED && d->on_audio) {
		int16_t pcm[MG_ISO_PACKETS * 1024 / 2];
		int bytes = 0, max = d->audio_pkt[d->info.alt];

		for (int i = 0; i < t->num_iso_packets; i++) {
			struct libusb_iso_packet_descriptor *p = &t->iso_packet_desc[i];

			if (p->status != LIBUSB_TRANSFER_COMPLETED || !p->actual_length ||
			    (int)p->actual_length > max || bytes + (int)p->actual_length > (int)sizeof(pcm))
				continue;
			memcpy((uint8_t *)pcm + bytes, libusb_get_iso_packet_buffer_simple(t, i), p->actual_length);
			bytes += p->actual_length;
		}
		int frames = bytes / 4;

		if (frames) {
			d->audio_frames += frames;
			d->on_audio(d->cb_ctx, pcm, frames, now - (uint64_t)frames * 1000000000ull / 48000);
		}
	}
	xfer_done(d, t);
}

static void *event_thread(void *arg)
{
	struct magica_dev *d = arg;
	struct timeval tv = { 0, 100000 };

	pthread_setname_np("magica.usb");
	while (d->active_xfers > 0) {
		int ret = libusb_handle_events_timeout_completed(d->ctx, &tv, NULL);

		if (ret == LIBUSB_ERROR_NO_DEVICE)
			d->gone = true;
		if (!d->running || d->gone) {
			/* cancel whatever is still queued; completions drain active_xfers */
			for (int i = 0; i < MG_VIDEO_XFERS; i++)
				if (d->vx[i])
					libusb_cancel_transfer(d->vx[i]);
			for (int i = 0; i < MG_AUDIO_XFERS; i++)
				if (d->ax[i])
					libusb_cancel_transfer(d->ax[i]);
			if (d->gone)
				break;
		}
	}
	return NULL;
}

static int choose_alt(struct magica_dev *d)
{
	/* em28xx_set_alternate: enough for a line plus header, doubled for full frames */
	int min_pkt = (d->width * 2 + 4) * 2, alt = 0;

	for (int i = 0; i < d->num_alt; i++) {
		if (d->video_pkt[i] >= min_pkt) {
			alt = i;
			break;
		}
		if (d->video_pkt[i] > d->video_pkt[alt])
			alt = i;
	}
	return alt;
}

static struct libusb_transfer *make_xfer(struct magica_dev *d, uint8_t ep, int pkt, int interval_unused,
					 libusb_transfer_cb_fn cb)
{
	(void)interval_unused;
	struct libusb_transfer *t = libusb_alloc_transfer(MG_ISO_PACKETS);
	uint8_t *buf = malloc((size_t)pkt * MG_ISO_PACKETS);

	if (!t || !buf) {
		libusb_free_transfer(t);
		free(buf);
		return NULL;
	}
	libusb_fill_iso_transfer(t, d->h, ep, buf, pkt * MG_ISO_PACKETS, MG_ISO_PACKETS, cb, d, 0);
	libusb_set_iso_packet_lengths(t, pkt);
	t->flags = LIBUSB_TRANSFER_FREE_BUFFER;
	return t;
}

static void free_xfers(struct magica_dev *d)
{
	for (int i = 0; i < MG_VIDEO_XFERS; i++) {
		libusb_free_transfer(d->vx[i]);
		d->vx[i] = NULL;
	}
	for (int i = 0; i < MG_AUDIO_XFERS; i++) {
		libusb_free_transfer(d->ax[i]);
		d->ax[i] = NULL;
	}
}

int magica_start(magica_dev *d, magica_field_cb on_field, magica_audio_cb on_audio, void *ctx)
{
	int ret;

	if (d->running)
		return MAGICA_EBUSY;
	if (d->gone)
		return MAGICA_EGONE;

	magica_parser_free(d->parser);
	d->parser = magica_parser_new(d->width, d->height, vbi_lines(d), on_field, ctx);
	if (!d->parser)
		return MAGICA_ENOMEM;
	d->on_field = on_field;
	d->on_audio = on_audio;
	d->cb_ctx = ctx;
	d->packet_errors = 0;
	d->audio_frames = 0;

	int alt = choose_alt(d);

	d->info.alt = alt;
	d->info.video_packet = d->video_pkt[alt];
	d->info.audio_packet = d->audio_pkt[alt];
	mg_info("streaming on alt %d: video %d bytes/µframe, audio %d", alt, d->video_pkt[alt], d->audio_pkt[alt]);

	pthread_mutex_lock(&d->ctrl);
	ret = libusb_set_interface_alt_setting(d->h, d->ifnum, alt);
	pthread_mutex_unlock(&d->ctrl);
	if (ret < 0) {
		mg_err("set alt %d: %s", alt, libusb_error_name(ret));
		return usb_err(d, ret);
	}

	for (int i = 0; i < MG_VIDEO_XFERS; i++)
		if (!(d->vx[i] = make_xfer(d, EP_VIDEO, d->video_pkt[alt], 1, video_cb)))
			goto nomem;
	if (on_audio && d->info.has_audio && d->audio_pkt[alt] > 0) {
		for (int i = 0; i < MG_AUDIO_XFERS; i++)
			if (!(d->ax[i] = make_xfer(d, EP_AUDIO, d->audio_pkt[alt], d->audio_interval, audio_cb)))
				goto nomem;
	}

	d->running = true;
	d->active_xfers = 0;
	for (int i = 0; i < MG_VIDEO_XFERS; i++) {
		if ((ret = libusb_submit_transfer(d->vx[i])) < 0)
			goto submit_failed;
		d->active_xfers++;
	}
	for (int i = 0; i < MG_AUDIO_XFERS && d->ax[i]; i++) {
		if ((ret = libusb_submit_transfer(d->ax[i])) < 0)
			goto submit_failed;
		d->active_xfers++;
	}

	/* em28xx_capture_start(dev, 1) */
	pthread_mutex_lock(&d->ctrl);
	em_write_bits(d, EM28XX_R0C_USBSUSP, 0x10, 0x10);
	em_write(d, 0x48, 0x00);
	ret = em_write(d, EM28XX_R12_VINENABLE, 0x67);
	if (d->ac97 && on_audio)
		audio_analog_set(d);
	pthread_mutex_unlock(&d->ctrl);
	msleep(10);
	if (ret < 0)
		goto submit_failed;

	if (pthread_create(&d->thread, NULL, event_thread, d) != 0) {
		ret = MAGICA_ENOMEM;
		goto submit_failed;
	}
	return 0;

submit_failed:
	mg_err("start streaming: %s", ret < -7 ? libusb_error_name(ret) : magica_strerror(ret));
	d->running = false;
	/* reap what was submitted */
	while (d->active_xfers > 0) {
		for (int i = 0; i < MG_VIDEO_XFERS; i++)
			if (d->vx[i])
				libusb_cancel_transfer(d->vx[i]);
		for (int i = 0; i < MG_AUDIO_XFERS; i++)
			if (d->ax[i])
				libusb_cancel_transfer(d->ax[i]);
		struct timeval tv = { 0, 100000 };

		if (libusb_handle_events_timeout_completed(d->ctx, &tv, NULL) < 0)
			break;
	}
	free_xfers(d);
	libusb_set_interface_alt_setting(d->h, d->ifnum, 0);
	return ret == LIBUSB_ERROR_NO_DEVICE ? MAGICA_EGONE : (ret < 0 && ret >= -7 ? ret : MAGICA_EIO);

nomem:
	free_xfers(d);
	return MAGICA_ENOMEM;
}

void magica_stop(magica_dev *d)
{
	if (!d->running && !d->vx[0])
		return;
	d->running = false;
	pthread_join(d->thread, NULL);
	free_xfers(d);

	if (!d->gone) {
		pthread_mutex_lock(&d->ctrl);
		/* em28xx_capture_start(dev, 0) */
		em_write_bits(d, EM28XX_R0C_USBSUSP, 0x00, 0x10);
		em_write(d, EM28XX_R12_VINENABLE, 0x27);
		libusb_set_interface_alt_setting(d->h, d->ifnum, 0);
		pthread_mutex_unlock(&d->ctrl);
	}
}
