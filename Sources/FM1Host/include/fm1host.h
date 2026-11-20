/* fm1host: runs an FM-1 .rfm1 firmware natively, on the wasm3 interpreter.
 *
 * A C port of FM-1 Pocket Player's src/rfm1.js (Jake Handy's FM-1 Browser Simulator, MIT), which drives a module
 * through the fm1core ABI 6 as RemoteFM1IOS's docs/RFM1-FORMAT.md describes. Same boot sequence, same clock (one
 * device millisecond at a time, a frame every 15 ms, 128-frame audio blocks at 44.1 kHz), same panel offsets.
 *
 * Every function is thread-safe: an internal mutex serialises the interpreter, so the audio thread can call
 * fm1h_pull() while the UI thread sends input or copies the screen.
 */
#ifndef FM1HOST_H
#define FM1HOST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FM1H_SAMPLE_RATE 44100
#define FM1H_SCREEN_W    240
#define FM1H_SCREEN_H    240
#define FM1H_NKEYS       27
#define FM1H_NBUTTONS    14
#define FM1H_NROLES      7

/* the 14 labelled buttons, in the order the ABI's button tables use */
enum { FM1H_FX, FM1H_SEL, FM1H_ENV, FM1H_LFO, FM1H_EDIT, FM1H_GLO, FM1H_HOME, FM1H_SAVE, FM1H_ARP, FM1H_SEQ,
       FM1H_PLAY, FM1H_REC, FM1H_OCT_DOWN, FM1H_OCT_UP };
/* the encoder roles */
enum { FM1H_SELECT, FM1H_ALGORITHM, FM1H_PRESETS, FM1H_KNOB1, FM1H_KNOB2, FM1H_KNOB3, FM1H_KNOB4 };
/* fm1h_info() fields */
enum { FM1H_INFO_ID, FM1H_INFO_NAME, FM1H_INFO_VERSION, FM1H_INFO_SOURCE_URL, FM1H_INFO_FAMILY, FM1H_INFO_LICENSE,
       FM1H_INFO_CREDITS };

typedef struct fm1h fm1h;

/* Loads, links and checks a module (the bytes are copied). Returns NULL and fills err on failure. */
fm1h *fm1h_create(const uint8_t *wasm, size_t len, char *err, size_t errlen);
void fm1h_destroy(fm1h *h);

int fm1h_abi(fm1h *h);
const char *fm1h_info(fm1h *h, int field);           /* never NULL; "" when absent */
const char *fm1h_button_name(fm1h *h, int label);    /* the firmware's own name, or the default label */
uint32_t fm1h_flash_size(fm1h *h);

/* power on, from a saved flash image (NULL/0 for a fresh one) */
void fm1h_boot(fm1h *h, const uint8_t *flash, size_t len);

/* the device clock */
void fm1h_run_ms(fm1h *h, int ms);
/* fills `frames` interleaved stereo float frames at 44.1 kHz, running the clock as far as needed (at most ~250 ms) */
void fm1h_pull(fm1h *h, float *out, int frames);
uint32_t fm1h_device_ms(fm1h *h);

/* the panel */
void fm1h_key(fm1h *h, int key, int down, int velocity);
void fm1h_button(fm1h *h, int label, int down);
void fm1h_turn(fm1h *h, int role, int detents);
void fm1h_set_master(fm1h *h, int value);             /* 0..1023 */
int fm1h_midi(fm1h *h, uint8_t status, uint8_t d1, uint8_t d2);   /* 1 taken, 0 not */

/* the screen as 240x240 RGBA8 (out: 230400 bytes); returns the panel's lcd_writes counter */
uint32_t fm1h_screen_rgba(fm1h *h, uint8_t *out);
uint32_t fm1h_lcd_writes(fm1h *h);
/* LED brightness 0..255 */
void fm1h_leds(fm1h *h, uint8_t buttons[FM1H_NBUTTONS], uint8_t keys[FM1H_NKEYS], uint8_t *play_green);

/* the flash image the firmware saves its settings in */
uint32_t fm1h_flash_dirty(fm1h *h);
/* copies the image into out (fm1h_flash_size bytes); sync asks the firmware to finish pending writes first.
   Returns the number of bytes copied (0 if none). */
size_t fm1h_flash_copy(fm1h *h, int sync, uint8_t *out, size_t cap);
void fm1h_shutdown(fm1h *h);

/* ---- optional extras a firmware may export (each returns "none" when it does not) ---- */

/* sim1: what each encoder role is tied to right now (docs/FIRMWARE-INTERFACE.md in FM-1 Pocket Player) */
typedef struct { int32_t value, lo, hi; char name[32]; char text[32]; } fm1h_ctl;
int fm1h_sim1(fm1h *h);                                /* the sim1 version, 0 without it */
int fm1h_ctl_info(fm1h *h, int role, fm1h_ctl *out);   /* -1 none, 0 a relative encoder, 1 a value to set outright */
void fm1h_ctl_set(fm1h *h, int role, int value);
int32_t fm1h_accent(fm1h *h);                          /* 0xRRGGBB, or -1 */
int32_t fm1h_link_bytes(fm1h *h);                      /* bytes the last frame sent to the panel, or -1 */
int fm1h_master(fm1h *h);                              /* the MASTER pot as the panel holds it, 0..1023 */
/* live labels (FM1VST): 49 slots, 0..7 the knob roles and MASTER, 8..21 the buttons, 22..37 the white keys,
   38..48 the black keys. The epoch is 0 when there are none and changes when any label changes. */
uint32_t fm1h_labels_epoch(fm1h *h);
int fm1h_label(fm1h *h, int slot, char *out, int cap); /* -1 not given, else the length ("" = no job here) */
int fm1h_stats(fm1h *h, uint32_t *shed, uint32_t *cpu);/* 1 if the firmware reports them */
/* bytes of the screen that changed at the last fm1h_screen_rgba (whole 480-byte rows), for the link meter */
uint32_t fm1h_screen_changed_bytes(fm1h *h);

/* 0 running; 0x1xx the firmware called exit(xx); 0x1ff a trap; 0x1fe out of memory */
int fm1h_halted(fm1h *h);
const char *fm1h_error(fm1h *h);
/* takes the firmware's stdout/stderr text since the last call (NUL-terminated, truncated to cap) */
size_t fm1h_log_take(fm1h *h, char *out, size_t cap);

#ifdef __cplusplus
}
#endif
#endif
