# File-library playable fixture

`file-library-three-seconds.mp4` is a synthetic, three-second black video with
a 440 Hz tone. It lets the iOS and macOS AppTests open and seek through Core's
WebDAV Range bridge using the actual Erika presenter, without launching desktop
tools from an iOS test host. It contains no user media.

Generated with:

```sh
ffmpeg -loglevel error -f lavfi -i 'color=c=black:s=64x36:r=10' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 3 \
  -c:v mpeg4 -c:a aac -movflags +faststart file-library-three-seconds.mp4
```

The original fixture remains in the repository; tests copy its bytes into
temporary media directories and serve them from their in-process HTTP fixture.
