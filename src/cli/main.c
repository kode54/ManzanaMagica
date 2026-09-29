// SPDX-License-Identifier: GPL-2.0-only
/* magica: command-line access to em28xx capture devices */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "magica.h"

static volatile sig_atomic_t stop;

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: magica [-v|-vv|-vvv] <command> [options]\n"
		"\n"
		"  probe                      identify the device and show the decoder status\n"
		"  status                     show lock/standard twice a second until ^C\n"
		"  capture [options]          stream video, print field statistics\n"
		"      --seconds N            stop after N seconds (default: until ^C)\n"
		"      --out FILE             write woven YUYV frames (ffplay -f rawvideo\n"
		"                             -pixel_format yuyv422 -video_size 720x480 FILE)\n"
		"      --std ntsc|pal|pal-m|pal-n|ntsc-j|secam|auto   (default auto)\n"
		"      --input composite|svideo\n");
	exit(2);
}

static void print_status(magica_dev *d)
{
	magica_status s;
	int ret = magica_status_get(d, &s);

	if (ret < 0) {
		printf("status: %s\n", magica_strerror(ret));
		return;
	}
	printf("signal %s, %s, colour %s\n", s.locked ? "LOCKED" : "no lock", s.is_50hz ? "50 Hz" : "60 Hz",
	       s.color ? "yes" : "no");
}

static int open_dev(magica_dev **d, magica_info *info)
{
	int ret = magica_open(d, info);

	if (ret < 0) {
		fprintf(stderr, "magica: %s\n", magica_strerror(ret));
		return ret;
	}
	return 0;
}

static int cmd_probe(void)
{
	magica_dev *d;
	magica_info info;

	if (open_dev(&d, &info) < 0)
		return 1;
	printf("%s (%04x:%04x)\n", info.board, info.vid, info.pid);
	printf("bridge   %s (chip id %d)\n", info.chip, info.chip_id);
	printf("decoder  %s\n", info.decoder);
	printf("audio    %s%s%s\n", info.audio, info.has_audio ? ", vendor isoc endpoint" : "",
	       info.usb_audio_class ? ", USB Audio Class interface (driven by macOS)" : "");
	print_status(d);
	magica_close(d);
	return 0;
}

static int cmd_status(void)
{
	magica_dev *d;

	if (open_dev(&d, NULL) < 0)
		return 1;
	while (!stop) {
		print_status(d);
		usleep(500000);
	}
	magica_close(d);
	return 0;
}

struct cap {
	FILE *out;
	uint8_t *frame;
	int width, height;
	int have_top;
	uint32_t frames;
};

static void on_field(void *ctx, const magica_field *f)
{
	struct cap *c = ctx;

	if (!c->out)
		return;
	/* weave: top field on even lines; a frame is top then bottom */
	for (int y = 0; y < f->lines; y++)
		memcpy(c->frame + (size_t)(2 * y + !f->top) * f->stride, f->data + (size_t)y * f->stride, f->stride);
	if (f->top) {
		c->have_top = 1;
	} else if (c->have_top) {
		fwrite(c->frame, 1, (size_t)c->width * 2 * c->height, c->out);
		c->frames++;
		c->have_top = 0;
	}
}

static const struct {
	const char *name;
	magica_std std;
} stds[] = {
	{ "ntsc", MAGICA_STD_NTSC_M }, { "ntsc-j", MAGICA_STD_NTSC_J }, { "pal-m", MAGICA_STD_PAL_M },
	{ "pal-60", MAGICA_STD_PAL_60 }, { "ntsc-443", MAGICA_STD_NTSC_443 }, { "pal", MAGICA_STD_PAL },
	{ "pal-n", MAGICA_STD_PAL_N }, { "secam", MAGICA_STD_SECAM },
};

static int cmd_capture(int argc, char **argv)
{
	double seconds = 0;
	const char *out = NULL, *stdname = "auto";
	magica_input input = MAGICA_INPUT_COMPOSITE;

	for (int i = 0; i < argc; i++) {
		if (!strcmp(argv[i], "--seconds") && i + 1 < argc)
			seconds = atof(argv[++i]);
		else if (!strcmp(argv[i], "--out") && i + 1 < argc)
			out = argv[++i];
		else if (!strcmp(argv[i], "--std") && i + 1 < argc)
			stdname = argv[++i];
		else if (!strcmp(argv[i], "--input") && i + 1 < argc)
			input = !strcmp(argv[++i], "svideo") ? MAGICA_INPUT_SVIDEO : MAGICA_INPUT_COMPOSITE;
		else
			usage();
	}

	magica_dev *d;

	if (open_dev(&d, NULL) < 0)
		return 1;
	magica_set_input(d, input);

	magica_std std = MAGICA_STD_NTSC_M;

	if (!strcmp(stdname, "auto")) {
		usleep(300000);
		int is50 = magica_detect_50hz(d);

		std = is50 == 1 ? MAGICA_STD_PAL : MAGICA_STD_NTSC_M;
		fprintf(stderr, "detected %s\n", is50 == 1 ? "50 Hz" : "60 Hz");
	} else {
		size_t i;

		for (i = 0; i < sizeof(stds) / sizeof(stds[0]); i++)
			if (!strcmp(stds[i].name, stdname))
				break;
		if (i == sizeof(stds) / sizeof(stds[0]))
			usage();
		std = stds[i].std;
	}
	magica_set_std(d, std);

	struct cap c = { .width = magica_width(d), .height = magica_height(d) };

	if (out) {
		c.out = fopen(out, "wb");
		if (!c.out) {
			perror(out);
			return 1;
		}
		c.frame = calloc(1, (size_t)c.width * 2 * c.height);
	}
	fprintf(stderr, "%s %dx%d\n", magica_std_name(std), c.width, c.height);

	int ret = magica_start(d, on_field, NULL, &c);

	if (ret < 0) {
		fprintf(stderr, "magica: %s\n", magica_strerror(ret));
		magica_close(d);
		return 1;
	}

	uint32_t last = 0;
	for (int ticks = 0; !stop && (seconds <= 0 || ticks < seconds * 2); ticks++) {
		usleep(500000);
		magica_status s;

		magica_status_get(d, &s);
		if (s.gone) {
			fprintf(stderr, "device unplugged\n");
			break;
		}
		fprintf(stderr, "fields %u (+%u) short %u packet errors %u, %s%s\n", s.fields, s.fields - last,
			s.short_fields, s.packet_errors, s.locked ? "locked" : "NO LOCK", s.is_50hz ? " 50 Hz" : " 60 Hz");
		last = s.fields;
	}
	magica_stop(d);
	magica_close(d);
	if (c.out) {
		fclose(c.out);
		fprintf(stderr, "wrote %u frames to %s\n", c.frames, out);
	}
	return 0;
}

int main(int argc, char **argv)
{
	int i = 1;

	for (; i < argc && argv[i][0] == '-' && argv[i][1] == 'v'; i++)
		magica_set_verbosity((int)strlen(argv[i]) - 1);
	if (i >= argc)
		usage();
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	const char *cmd = argv[i++];

	if (!strcmp(cmd, "probe"))
		return cmd_probe();
	if (!strcmp(cmd, "status"))
		return cmd_status();
	if (!strcmp(cmd, "capture"))
		return cmd_capture(argc - i, argv + i);
	usage();
}
