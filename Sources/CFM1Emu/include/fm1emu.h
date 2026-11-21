/* Upstream fm1-emu's C functions (joakimeriksson/fm1-emu, MIT; crates/fm1-web/src/lib.rs at the commit pinned in
 * Emu/Cargo.toml), linked from Vendor/fm1emu/libfm1emu_pocket.a (scripts/build-emu.sh). One machine per process:
 * every call acts on the machine the last boot made. Not thread-safe: PocketKit's EmuCore serialises calls. */
#pragma once
#include <stdint.h>

uint8_t *fm1_alloc(uint32_t len);                       /* bytes the next boot / restore / script takes over */
uint32_t fm1_boot_fwsc(uint8_t *pkg, uint32_t len, uint8_t *syx, uint32_t syx_len, uint32_t mhz); /* 0 ok, 1 not a package */
void fm1_jit(uint32_t on, uint32_t per_render);
void fm1_ahead(uint32_t frames);
uint32_t fm1_render(uint32_t frames, uint32_t max_insns); /* runs until `frames` stereo frames exist; returns how many */
const float *fm1_out_l(void);
const float *fm1_out_r(void);
const uint16_t *fm1_lcd(void);                          /* 240 x 240 RGB565 */
uint32_t fm1_lcd_revision(void);
const float *fm1_leds(void);                            /* 41: matrix ids 0..13 buttons, 14..40 keys; 0..1 */
void fm1_key(uint32_t id, uint32_t down);               /* matrix id: 0..13 buttons, 14 + n the note keys (F3 = 0) */
void fm1_enc(uint32_t enc, int32_t clicks);
void fm1_midi(uint32_t byte);                           /* into the MIDI IN jack */
void fm1_pot(uint32_t value);                           /* MASTER, 0..1023 */
uint32_t fm1_bench_script(uint8_t *script, uint32_t len); /* "ms:n7@110,..." (fm1_soc::script) */
const uint8_t *fm1_flash(void);
const uint8_t *fm1_flash_base(void);                    /* the flash as the package booted it */
uint32_t fm1_flash_len(void);
uint32_t fm1_flash_revision(void);
uint32_t fm1_flash_busy(void);
uint32_t fm1_flash_restore(uint8_t *records, uint32_t len); /* before the first render: 0 ok */
uint32_t fm1_ms(void);
uint32_t fm1_halted(void);
uint32_t fm1_board(void);                               /* 0 FM-1, 1 SMK-37 */
