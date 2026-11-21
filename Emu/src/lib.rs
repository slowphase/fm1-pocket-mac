//! Nothing but a re-export: the C functions are upstream's own (crates/fm1-web/src/lib.rs at the pinned commit):
//! fm1_alloc, fm1_boot_fwsc, fm1_render, fm1_out_l/r, fm1_lcd, fm1_lcd_revision, fm1_leds, fm1_key, fm1_enc,
//! fm1_midi, fm1_pot, fm1_flash, fm1_flash_base, fm1_flash_len, fm1_flash_revision, fm1_flash_restore,
//! fm1_bench_script, fm1_ms, fm1_halted. No emulator code lives in this repository.
pub use fm1_web::*;
