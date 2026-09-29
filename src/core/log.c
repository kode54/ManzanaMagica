// SPDX-License-Identifier: GPL-2.0-only
#include <stdarg.h>
#include <stdio.h>

#include "internal.h"

static int verbosity = 0;
static magica_log_fn log_fn;

void magica_set_verbosity(int level)
{
	verbosity = level;
}

void magica_set_log(magica_log_fn fn)
{
	log_fn = fn;
}

int mg_log_enabled(int level)
{
	return level <= verbosity;
}

void mg_log(int level, const char *fmt, ...)
{
	char msg[512];
	va_list ap;

	if (level > verbosity)
		return;
	va_start(ap, fmt);
	vsnprintf(msg, sizeof(msg), fmt, ap);
	va_end(ap);
	if (log_fn)
		log_fn(level, msg);
	else
		fprintf(stderr, "magica: %s\n", msg);
}

const char *magica_strerror(int err)
{
	switch (err) {
	case MAGICA_OK: return "ok";
	case MAGICA_ENODEV: return "no supported capture device found";
	case MAGICA_EBUSY: return "the device is in use by another program";
	case MAGICA_EIO: return "USB transfer failed";
	case MAGICA_EUNSUPPORTED: return "unsupported device";
	case MAGICA_EINVAL: return "invalid argument";
	case MAGICA_ENOMEM: return "out of memory";
	case MAGICA_EGONE: return "the device was unplugged";
	}
	return "unknown error";
}

const char *magica_std_name(magica_std s)
{
	switch (s) {
	case MAGICA_STD_NTSC_M: return "NTSC";
	case MAGICA_STD_NTSC_J: return "NTSC-J";
	case MAGICA_STD_PAL_M: return "PAL-M";
	case MAGICA_STD_PAL_60: return "PAL-60";
	case MAGICA_STD_NTSC_443: return "NTSC 4.43";
	case MAGICA_STD_PAL: return "PAL";
	case MAGICA_STD_PAL_N: return "PAL-N";
	case MAGICA_STD_SECAM: return "SECAM";
	}
	return "?";
}
