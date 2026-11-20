/* native_smoke: FM-1 Pocket Player's boot test (pocket/smoke.mjs), run in the Mac app's own engine (fm1host on wasm3).
 * The same steps and the same thresholds, so the two players' results can be compared:
 *   boot fresh, run 6 s; idle sound; the screen; a chord, single keys, MIDI notes, and PLAY if still silent;
 *   KNOB 1, PRESETS, HOME; did the screen change.
 *
 *   native_smoke FILE.rfm1        -> one line of JSON on stdout (always exit 0 unless the file cannot be read)
 *
 * Passing it does not prove a firmware is safe, or that it behaves as on a real FM-1. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "fm1host.h"

#define SILENT 0.0002
#define RUNTIME "fm1host + wasm3 0.5.0"

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static float buf[88200 * 2];
static double hear(fm1h *h, int frames) {
    double s = 0;
    fm1h_pull(h, buf, frames);
    for (int i = 0; i < frames * 2; i++) s += (double)buf[i] * buf[i];
    return sqrt(s / (frames * 2));
}
static void json_str(const char *s) {
    putchar('"');
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') printf("\\%c", c);
        else if (c < 0x20) printf("\\u%04x", c);
        else putchar(c);
    }
    putchar('"');
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: native_smoke FILE.rfm1\n"); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *b = malloc((size_t)len);
    if (!b || fread(b, 1, (size_t)len, f) != (size_t)len) { fclose(f); return 2; }
    fclose(f);

    double t0 = now();
    char err[300];
    fm1h *h = fm1h_create(b, (size_t)len, err, sizeof err);
    if (!h) {
        printf("{\"crashed\":"); json_str(err); printf(",\"runtime\":\"%s\"}\n", RUNTIME);
        return 0;
    }
    fm1h_boot(h, NULL, 0);
    fm1h_run_ms(h, 6000);                                   /* past a splash screen or a slow start */
    double idle = hear(h, 4410);
    static unsigned char rgba[240 * 240 * 4];
    unsigned writes = fm1h_screen_rgba(h, rgba), lit = 0;
    for (int i = 0; i < 240 * 240; i++) if (rgba[4 * i] | rgba[4 * i + 1] | rgba[4 * i + 2]) lit++;

    double played = 0, r;
    const char *how = "";
    int chord[3] = { 7, 11, 14 };
    for (int i = 0; i < 3; i++) fm1h_key(h, chord[i], 1, 110);
    fm1h_run_ms(h, 20);
    if ((r = hear(h, 44100)) > played) { played = r; how = "chord"; }
    for (int i = 0; i < 3; i++) fm1h_key(h, chord[i], 0, 0);
    fm1h_run_ms(h, 300);
    int keys[8] = { 7, 11, 14, 12, 19, 9, 16, 7 };
    for (int i = 0; i < 8; i++) {
        fm1h_key(h, keys[i], 1, 115); fm1h_run_ms(h, 5);
        if ((r = hear(h, 17640)) > played) { played = r; how = "key"; }
        fm1h_key(h, keys[i], 0, 0); fm1h_run_ms(h, 120);
    }
    int notes[3] = { 48, 60, 72 };
    for (int i = 0; i < 3; i++) {
        fm1h_midi(h, 0x90, (uint8_t)notes[i], 110);
        if ((r = hear(h, 22050)) > played) { played = r; how = "midi"; }
        fm1h_midi(h, 0x80, (uint8_t)notes[i], 0); fm1h_run_ms(h, 100);
    }
    if (played <= SILENT && idle <= SILENT) {
        fm1h_button(h, FM1H_PLAY, 1); fm1h_run_ms(h, 80); fm1h_button(h, FM1H_PLAY, 0);
        if ((r = hear(h, 88200)) > played) { played = r; how = "play"; }
        fm1h_button(h, FM1H_PLAY, 1); fm1h_run_ms(h, 80); fm1h_button(h, FM1H_PLAY, 0);
    }
    fm1h_turn(h, FM1H_KNOB1, 3);
    fm1h_turn(h, FM1H_PRESETS, 1);
    fm1h_button(h, FM1H_HOME, 1); fm1h_run_ms(h, 80); fm1h_button(h, FM1H_HOME, 0);
    fm1h_run_ms(h, 800);
    unsigned writes2 = fm1h_lcd_writes(h);
    double secs = now() - t0;
    int halted = fm1h_halted(h);

    printf("{\"id\":"); json_str(fm1h_info(h, FM1H_INFO_ID));
    printf(",\"abi\":%d,\"halted\":%d,\"error\":", fm1h_abi(h), halted);
    if (halted) json_str(fm1h_error(h)); else printf("null");
    printf(",\"litPixels\":%u,\"lcdWrites\":[%u,%u],\"idleRms\":%.4f,\"playedRms\":%.4f,\"soundFrom\":",
           lit, writes, writes2, idle, played);
    if (*how) json_str(how); else printf("null");
    printf(",\"sounds\":%s,\"draws\":%s,\"redraws\":%s,\"speed\":%.1f,\"runtime\":\"%s\"}\n",
           (idle > SILENT || played > SILENT) ? "true" : "false", lit > 0 ? "true" : "false",
           writes2 > writes ? "true" : "false", fm1h_device_ms(h) / 1000.0 / (secs > 0 ? secs : 1), RUNTIME);
    fm1h_destroy(h);
    free(b);
    return 0;
}
