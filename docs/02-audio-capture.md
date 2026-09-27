# 2. Audio capture

What you'll learn: what digital audio is, why speech models want 16 kHz mono, and how to
capture another app's sound on macOS.

## Concepts

**Digital audio** is a list of numbers (*samples*): the air pressure measured many times per
second. 48,000 samples per second (48 kHz) is typical for playback. Each sample here is a
`Float` between −1 and 1.

**Speech models want 16 kHz mono.** Human speech carries almost all its information below
8 kHz, and a 16 kHz sample rate captures frequencies up to 8 kHz (the Nyquist limit: half
the sample rate). Whisper and Silero VAD were trained on 16 kHz mono, so everything is
converted to that: one channel, 16,000 samples per second. **Resampling** from 48 kHz is
done with `AVAudioConverter`, which filters out higher frequencies first so they don't
fold back into the result as noise (*aliasing*).

**Buffers and callbacks.** Audio arrives in small chunks (~10–100 ms) on a real-time thread.
Work there must be quick; heavy processing happens elsewhere.

## How Subtitler does it

`AudioCapture` is a protocol delivering 16 kHz mono `[Float]` to `onSamples`.

**Core Audio process tap** (macOS 14.2+, `CoreAudioTapCapture`):

1. A `CATapDescription` asks for a **mono global tap** of everything the Mac plays,
   excluding Subtitler's own process.
2. A private **aggregate device** combines the default output device with the tap.
3. An IO callback copies each buffer (the tap's is the *last* one; devices with inputs put
   theirs first) and resamples it to 16 kHz.
4. When the output device changes (AirPods connect), the tap is rebuilt.

It needs only the **System Audio Recording** permission; it never sees the screen. On
macOS 14.0–14.1 a ScreenCaptureKit stream is the fallback, which needs Screen Recording.

Core Audio objects are created and destroyed on a control queue and IO runs on another, so
stopping the device can't deadlock waiting on its own callback queue.

## Try it

```sh
# Is the permission granted? If so, capture 3 s and print the loudness (RMS).
app/build/Subtitler.app/Contents/MacOS/Subtitler --audio-probe
```

Play something while it runs: RMS near 0 means silence, ~0.05–0.2 is normal speech.

## Code map

- `app/Sources/Subtitler/Audio/CoreAudioTapCapture.swift`: the tap and `AudioCaptureFactory`
- `app/Sources/Subtitler/Audio/SystemAudioCapture.swift`: ScreenCaptureKit fallback
- `app/Sources/Subtitler/Audio/AudioPermission.swift`: permission status

## Further reading

- Apple, "Capturing system audio with Core Audio taps": https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- Nyquist–Shannon sampling theorem: https://en.wikipedia.org/wiki/Nyquist%E2%80%93Shannon_sampling_theorem
