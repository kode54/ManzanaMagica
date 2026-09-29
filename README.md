# ManzanaMagica

A Mac app for watching and recording analog video (composite and S-Video) from
**Empia em28xx** USB capture devices, starting with the **MyGica iGrabber**
(`1f4d:1abe`: EM2860 bridge, Philips SAA7113 decoder, EMP202 AC'97 codec).
macOS has no driver for these, so ManzanaMagica drives the bridge and the
decoder itself from user space with libusb. There's no kernel extension, no
DriverKit, and nothing else to install. It's a sibling of
[ManzanaVision](https://github.com/kddlb/ManzanaVision) and shares its GPU
YADIF deinterlacer.

## Using the app

- Pick **Composite** or **S-Video** in the toolbar. The standard follows the
  source (525/60 NTSC or 625/50 PAL) unless you fix it to NTSC, NTSC-J, PAL-M,
  PAL-60, NTSC 4.43, PAL, PAL-N or SECAM.
- The picture is deinterlaced on the GPU with YADIF to 59.94 (or 50) frames per
  second. Bob and "off" are in Settings, along with brightness, contrast,
  saturation and hue.
- **Record** (⌘R) writes a QuickTime movie (.mov) to Movies/ManzanaMagica, encoded with the
  system's H.264 or HEVC encoder and AAC sound. It records either at the
  native SD size (with its pixel aspect ratio flagged), or scaled to 720p with
  square pixels and BT.709 colour, ready for YouTube: 960×720 (4:3), or
  1280×720 with the picture pillarboxed.
- The sound comes from the device's USB Audio Class interface, which macOS
  drives itself. The app plays it live and needs microphone permission for
  that.

## Command-line tools

```sh
swift build
.build/debug/magica probe                      # identify the chips, show lock status
.build/debug/magica -v capture --input svideo --seconds 5 --out cap.yuv
ffplay -f rawvideo -pixel_format yuyv422 -video_size 720x480 cap.yuv
.build/debug/mgtool record out.mov --input svideo --seconds 30 --codec hevc --size hd720
```

`-v`, `-vv` and `-vvv` add info, debug and USB register traces.

## Building

- **App:** open `App/ManzanaMagica/ManzanaMagica.xcodeproj` in Xcode 27 and run.
- **Libraries, tools and tests:** `swift build`, `swift test`.

## How it works

```
src/core/em28xx.c     bridge registers, I2C, AC'97, isochronous streaming (libusb)
src/core/saa711x.c    SAA7113 / GM7113C / CJC7113 decoder setup
src/core/parser.c     isoc packet headers → whole fields
src/cli/              the magica command
Sources/MagicaCapture device wrapper, hot-plug, fields → CVPixelBuffers, audio input
Sources/MagicaPlayback YADIF on Metal, live display, recording
Sources/mgtool        headless recording through the same pipeline
App/                  the SwiftUI app
```

The driver is a port of the Linux `em28xx` and `saa7115` drivers, restricted
to what these boards need, in the same register order.

Notes from bringing it up on real hardware:

- The em2860 sends each field as 12 (NTSC) or 18 (PAL) lines of raw VBI and
  then the picture, in YUYV. Because the capture window starts two lines
  down, each field arrives two lines short. Linux passes those lines on stale;
  here the last line is repeated.
- The iGrabber's vendor audio endpoint (0x83) is unused. Its line input also
  appears as a standard USB audio device, and that's the one used for sound.
- Fields are paired top-then-bottom into 4:2:2 frames, so each field keeps
  its own chroma, and YADIF runs on both planes.

## License

GPL-2.0-only, like the Linux drivers it's ported from. See [LICENSE](LICENSE).
libusb is LGPL-2.1 (`vendor/libusb`).
