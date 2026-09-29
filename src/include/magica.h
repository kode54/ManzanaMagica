/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * ManzanaMagica: user-space driver for Empia em28xx analog capture bridges
 * (starting with the em2860 + SAA7113 + EMP202 MyGica iGrabber), on libusb.
 *
 * The device delivers interlaced YUYV 4:2:2 one field at a time, and
 * 48 kHz 16-bit stereo PCM from the AC'97 codec, both over isochronous
 * endpoints. Callbacks run on the library's USB event thread.
 */
#ifndef MAGICA_H
#define MAGICA_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
	MAGICA_OK = 0,
	MAGICA_ENODEV = -1,	/* no supported device plugged in */
	MAGICA_EBUSY = -2,	/* another program has it open */
	MAGICA_EIO = -3,	/* USB or I2C transfer failed */
	MAGICA_EUNSUPPORTED = -4, /* bridge or decoder we don't drive (yet) */
	MAGICA_EINVAL = -5,
	MAGICA_ENOMEM = -6,
	MAGICA_EGONE = -7,	/* the device was unplugged */
};

typedef enum {
	MAGICA_INPUT_COMPOSITE = 0,
	MAGICA_INPUT_SVIDEO = 1,
} magica_input;

/* Colour standards the SAA7113 can decode */
typedef enum {
	MAGICA_STD_NTSC_M = 0,	/* 525/60, 3.58 MHz */
	MAGICA_STD_NTSC_J,	/* 525/60, no setup */
	MAGICA_STD_PAL_M,	/* 525/60, Brazil */
	MAGICA_STD_PAL_60,	/* 525/60, 4.43 MHz */
	MAGICA_STD_NTSC_443,	/* 525/60 NTSC on a 4.43 MHz carrier */
	MAGICA_STD_PAL,		/* 625/50 B/G/D/H/I */
	MAGICA_STD_PAL_N,	/* 625/50 Argentina, Paraguay, Uruguay */
	MAGICA_STD_SECAM,	/* 625/50 */
} magica_std;

static inline int magica_std_is_50hz(magica_std s)
{
	return s >= MAGICA_STD_PAL;
}

typedef struct {
	uint16_t vid, pid;
	char board[48];		/* e.g. "MyGica iGrabber" */
	char chip[16];		/* bridge, e.g. "em2860" */
	int chip_id;
	char decoder[16];	/* e.g. "saa7113" */
	char audio[48];		/* e.g. "EMP202 AC'97", "none" */
	int has_audio;		/* vendor audio on the isoc endpoint 0x83 */
	int usb_audio_class;	/* a USB Audio Class interface exists (the OS drives it) */
	int alt;		/* alternate setting used for streaming */
	int video_packet;	/* bytes per microframe on the video endpoint */
	int audio_packet;
} magica_info;

typedef struct {
	const uint8_t *data;	/* YUYV (Y0 Cb Y1 Cr), `lines` rows of `stride` bytes */
	int width;
	int lines;
	int stride;
	int top;		/* 1: this field holds the frame's even lines (0, 2, …) */
	int complete;		/* 0: the field was cut short, the tail is stale */
	uint32_t seq;		/* field counter since start */
	uint64_t time_ns;	/* CLOCK_UPTIME_RAW when the field started arriving */
} magica_field;

typedef void (*magica_field_cb)(void *ctx, const magica_field *f);
/* 48 kHz interleaved stereo s16, `frames` sample frames */
typedef void (*magica_audio_cb)(void *ctx, const int16_t *pcm, int frames, uint64_t time_ns);

typedef struct {
	int locked;		/* the decoder has horizontal and vertical lock */
	int is_50hz;		/* the decoder sees a 50 Hz signal */
	int color;		/* a colour burst was detected (not 100% reliable) */
	int streaming;
	uint32_t fields;	/* delivered since start */
	uint32_t short_fields;	/* cut short (lost packets) */
	uint32_t packet_errors;	/* isoc packets with an error status */
	uint32_t audio_frames;
	int gone;
} magica_status;

typedef struct magica_dev magica_dev;

/* Opens the first supported device, identifies its chips and initialises them */
int magica_open(magica_dev **out, magica_info *info);
void magica_close(magica_dev *d);

int magica_set_input(magica_dev *d, magica_input input);
int magica_set_std(magica_dev *d, magica_std std);
/* Reads the decoder's field-rate detector: 1 = 50 Hz, 0 = 60 Hz, <0 error */
int magica_detect_50hz(magica_dev *d);
/* SAA7113 picture controls: brightness 0–255 (128), contrast 0–127 (64),
 * saturation 0–127 (64), hue -128–127 (0) */
int magica_set_picture(magica_dev *d, int brightness, int contrast, int saturation, int hue);
/* Line-in capture gain, 0 (-0 dB)… 31; mute */
int magica_set_audio(magica_dev *d, int volume, int mute);

int magica_status_get(magica_dev *d, magica_status *st);

/* Frame geometry for the current standard */
int magica_width(magica_dev *d);
int magica_height(magica_dev *d);

int magica_start(magica_dev *d, magica_field_cb on_field, magica_audio_cb on_audio, void *ctx);
void magica_stop(magica_dev *d);

const char *magica_strerror(int err);
const char *magica_std_name(magica_std s);

/* Logging: 0 = errors, 1 = info, 2 = debug, 3 = register trace */
void magica_set_verbosity(int level);
typedef void (*magica_log_fn)(int level, const char *msg);
void magica_set_log(magica_log_fn fn);

/*
 * Copies one field of YUYV into every other row of a biplanar 4:2:2 picture
 * (a luma plane, and an interleaved CbCr plane at half width), starting at
 * row `parity` (0 = top field)
 */
void magica_weave_field(const magica_field *f, int parity, uint8_t *y, int y_stride, uint8_t *cbcr, int cbcr_stride);

/* The packet parser on its own, for tests and replaying captures */
typedef struct magica_parser magica_parser;
magica_parser *magica_parser_new(int width, int height, int vbi_lines,
				 magica_field_cb cb, void *ctx);
void magica_parser_free(magica_parser *p);
/* One isochronous packet's payload */
void magica_parser_feed(magica_parser *p, const uint8_t *pkt, int len, uint64_t time_ns);
void magica_parser_counters(magica_parser *p, uint32_t *fields, uint32_t *short_fields);

#ifdef __cplusplus
}
#endif

#endif
