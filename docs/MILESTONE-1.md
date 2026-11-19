# Milestone 1: technical proof of concept

## The question

Can a native Mac app run FM-1 Pocket Player's `.rfm1` firmware without a browser?

## What an .rfm1 is

An `.rfm1` is an FM-1 firmware's "host build" compiled to WebAssembly, with a JSON manifest inside it. The format
belongs to the FM-1 community (RemoteFM1IOS `docs/RFM1-FORMAT.md`) and wraps FM1VST's `fm1core` ABI version 6. The
same files run in FM-1 Pocket Player (browser), RemoteFM1 for iOS and FM1VST.

The host interface is small, which is what makes a native player practical:

- **Imports:** only `wasi_snapshot_preview1` (stdout/stderr, a clock, `proc_exit`; everything else is a stub).
  h1 imports nothing at all.
- **Exports:** `rfm1_init`, `rfm1_tick(ms)`, `rfm1_frame`/`rfm1_idle`, `rfm1_audio(buf, 128)`, the flash calls,
  `rfm1_midi_in`, and a descriptor whose `panel` struct holds the keys, buttons, encoders, MASTER, LEDs and the
  240x240 RGB565 screen.
- **Clock:** the host calls the firmware once per device millisecond, a frame every 15 ms, and 128-frame audio blocks
  at 44.1 kHz.

## Runtime decision: wasm3

| Option | Verdict |
| --- | --- |
| **wasm3** (C interpreter, MIT) | **Chosen.** Small, builds with Xcode's clang as plain C in the Swift package, no JIT (so no special code-signing entitlements). RemoteFM1IOS, the format's own iOS host, already runs `.rfm1` files on wasm3 and measured heavy firmware (Felucca, ChoralRoot) at 15–40x real time on an M5 Max. |
| WAMR fast interpreter | 10–25 % slower than wasm3 in RemoteFM1IOS's measurements, bigger build. |
| WasmKit (Swift) | Pure Swift, but no published `.rfm1` track record; would need its own speed proof. |
| Wasmtime / JIT engines | Fastest, but a large prebuilt Rust library, and JIT needs extra entitlements. Not needed at these speeds. |
| JavaScriptCore / WKWebView | Ruled out by the brief (browser-based). |
| joakimeriksson/fm1-emu | Emulates the FM-1's JieLi CPU to run device `.fwsc` packages. Different format and architecture; it cannot run `.rfm1` files, so it is not used. It could matter later only for firmware that has no `.rfm1` build. |

RemoteFM1IOS is GPL-3.0, so none of its code is copied. Our host (`Sources/FM1Host/fm1host.c`) is a fresh C port of
Pocket Player's MIT-licensed `src/rfm1.js`, so the Mac app behaves the way Pocket does: same boot sequence, same
clock, same panel offsets, same layout checks.

## Evidence so far

### Measured in the development sandbox (Linux, 2-core x86 cloud VM, much slower than an M5)

The C host test (`Tests/ctest`, the same checks as Pocket's `tests/run.js`) on h1 and six firmwares from
RemoteFM1FW's release:

| Firmware | Boots | Draws | Sound | Reacts to input | Speed |
| --- | --- | --- | --- | --- | --- |
| h1 0.2.1 | yes | yes | yes | yes | 7.0x real time |
| Felucca 1.8.2 | yes | yes | yes | yes | 13.3x |
| GR!MM 2.0.2 | yes | yes | yes | yes | 2.4x |
| SLOOP 2.8.5 | yes | yes | yes | yes | 10.9x |
| SLOOP 3 3.4.0 | yes | yes | yes | yes | 11.5x |
| ChoralRoot 0.42 | yes | yes | yes | yes | 8.7x |
| AMB-1 1.3.2 | yes | yes | yes (generative) | yes | 10.8x |

h1 also played a MIDI note-on. Screens were saved and inspected: each shows the firmware's real home screen.

### On GitHub's Apple Silicon Mac

See the latest **Build Mac app** run's summary: the C host test, the Swift tests (including h1's speed on that Mac),
the live-catalogue check and the packaged app's self-test.

## What is still untested

- **Sound on a real Mac's speakers or headphones.** CI runners have no audio device; the tests check the samples
  the firmware produces, not what you hear. Needs you to press Play.
- **On-screen controls and computer-keyboard input in the real window.** The same calls are tested headless.
- **MIDI from a real controller.** The firmware side is tested; the Mac's CoreMIDI input is not built yet
  (Milestone 3).
- **Every catalogue firmware.** Seven families are proven; the live check boots one catalogue firmware per build.
- **GR!MM-class heavy firmware at small audio buffers.** It ran 2.4x real time on the slow sandbox; an M5 should be
  several times faster, but this needs measuring on your Mac.

## Problems to solve later

- **The `sim1` extension and live labels** (knob values, what each button does) are not read yet. Needed for the
  faceplate in Milestone 3.
- **Saved settings are kept per firmware version**, as the brief asks. Pocket keeps them per firmware id, so an
  update there keeps your settings; here an update starts fresh. Milestone 4 should decide whether to carry the
  previous version's state forward.
- **Audio threading.** The audio callback runs the firmware under a lock the UI also takes briefly. Fine so far;
  if dropouts appear, input can move to a lock-free queue.
- **No app icon yet** (Milestone 5).
