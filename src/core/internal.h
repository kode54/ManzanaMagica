/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef MAGICA_INTERNAL_H
#define MAGICA_INTERNAL_H

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>

#include "magica.h"

struct libusb_context;
struct libusb_device_handle;
struct libusb_transfer;

#define MG_MAX_ALTS 16
#define MG_VIDEO_XFERS 8
#define MG_AUDIO_XFERS 8
#define MG_ISO_PACKETS 64

struct magica_dev {
	struct libusb_context *ctx;
	struct libusb_device_handle *h;
	magica_info info;
	pthread_mutex_t ctrl;		/* one register/I2C conversation at a time */
	int wait_after_write_ms;
	bool gone;

	/* USB layout */
	int ifnum;
	int num_alt;
	int video_pkt[MG_MAX_ALTS];	/* per alt, bytes per (micro)frame */
	int audio_pkt[MG_MAX_ALTS];
	int audio_interval;

	/* decoder */
	uint8_t saa_addr;		/* 8-bit I2C address */
	int saa_ident;
	magica_input input;
	magica_std std;
	int width, height;

	/* audio */
	int ac97;			/* 0 none, 1 EMP202, 2 other */
	int volume, mute;

	/* streaming */
	volatile bool running;
	pthread_t thread;
	struct libusb_transfer *vx[MG_VIDEO_XFERS];
	struct libusb_transfer *ax[MG_AUDIO_XFERS];
	int active_xfers;
	magica_parser *parser;
	magica_field_cb on_field;
	magica_audio_cb on_audio;
	void *cb_ctx;
	uint32_t packet_errors;
	uint32_t audio_frames;
};

/* em28xx.c */
int em_read(struct magica_dev *d, uint16_t reg);
int em_read_len(struct magica_dev *d, uint8_t req, uint16_t reg, uint8_t *buf, int len);
int em_write(struct magica_dev *d, uint16_t reg, uint8_t val);
int em_write_len(struct magica_dev *d, uint8_t req, uint16_t reg, const uint8_t *buf, int len);
int em_write_bits(struct magica_dev *d, uint16_t reg, uint8_t val, uint8_t mask);
int em_i2c_write(struct magica_dev *d, uint8_t addr, const uint8_t *buf, int len, int stop);
int em_i2c_read(struct magica_dev *d, uint8_t addr, uint8_t *buf, int len);
int em_ac97_read(struct magica_dev *d, uint8_t reg);
int em_ac97_write(struct magica_dev *d, uint8_t reg, uint16_t val);

/* saa711x.c */
int saa_probe(struct magica_dev *d);
int saa_set_input(struct magica_dev *d, magica_input input);
int saa_set_std(struct magica_dev *d, magica_std std);
int saa_status(struct magica_dev *d);	/* status byte 0x1f, or <0 */
int saa_set_picture(struct magica_dev *d, int brightness, int contrast, int saturation, int hue);

/* log.c */
void mg_log(int level, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
int mg_log_enabled(int level);

#define mg_err(...) mg_log(0, __VA_ARGS__)
#define mg_info(...) mg_log(1, __VA_ARGS__)
#define mg_dbg(...) mg_log(2, __VA_ARGS__)

#endif
