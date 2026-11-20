/* Boots an .rfm1 headless and checks it powers on, draws, sounds when played, reacts to input and hands back its
 * flash: the same checks as FM-1 Pocket Player's tests/run.js. Prints the speed as "x realtime".
 *   host_test file.rfm1 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "fm1host.h"

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static double rms(const float *a, int n) { double s = 0; for (int i = 0; i < n; i++) s += a[i] * a[i]; return sqrt(s / n); }

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: host_test file.rfm1\n"); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *b = malloc(len);
    if (fread(b, 1, len, f) != (size_t)len) return 2;
    fclose(f);

    char err[300];
    double t0 = now();
    fm1h *h = fm1h_create(b, len, err, sizeof err);
    if (!h) { printf("FAIL load: %s\n", err); return 1; }
    double tl = now();
    printf("loaded %s %s (abi %d, %s) in %.1f ms; flash %u bytes\n", fm1h_info(h, FM1H_INFO_NAME),
           fm1h_info(h, FM1H_INFO_VERSION), fm1h_abi(h), fm1h_info(h, FM1H_INFO_LICENSE), (tl - t0) * 1e3, fm1h_flash_size(h));

    fm1h_boot(h, NULL, 0);
    fm1h_run_ms(h, 1500);
    static float buf[22050 * 2];
    fm1h_pull(h, buf, 4410);
    double idle = rms(buf, 4410 * 2);
    static unsigned char rgba[240 * 240 * 4];
    unsigned writes = fm1h_screen_rgba(h, rgba), lit = 0;
    if (argc > 2) {                                  /* host_test file.rfm1 screen.ppm: save the screen */
        FILE *o = fopen(argv[2], "wb");
        if (o) { fprintf(o, "P6 240 240 255\n"); for (int i = 0; i < 240 * 240; i++) fwrite(rgba + 4 * i, 1, 3, o); fclose(o); }
    }
    for (int i = 0; i < 240 * 240; i++) if (rgba[4 * i] | rgba[4 * i + 1] | rgba[4 * i + 2]) lit++;

    int chord[3] = { 7, 11, 14 };
    for (int i = 0; i < 3; i++) fm1h_key(h, chord[i], 1, 100);
    fm1h_run_ms(h, 50);
    fm1h_pull(h, buf, 22050);
    double played = rms(buf, 22050 * 2);
    for (int i = 0; i < 3; i++) fm1h_key(h, chord[i], 0, 0);
    fm1h_turn(h, FM1H_KNOB1, 3);
    fm1h_turn(h, FM1H_PRESETS, 1);
    fm1h_button(h, FM1H_HOME, 1); fm1h_run_ms(h, 80); fm1h_button(h, FM1H_HOME, 0);
    fm1h_run_ms(h, 600);
    unsigned writes2 = fm1h_lcd_writes(h);
    unsigned char *flash = malloc(fm1h_flash_size(h) + 1);
    size_t fl = fm1h_flash_copy(h, 1, flash, fm1h_flash_size(h));

    /* speed: a fresh boot, the default preset, a chord held, 10 s of device time pulled in 512-frame buffers
       (the same measurement as the Swift test and the app's self-test) */
    fm1h *sp = fm1h_create(b, len, err, sizeof err);
    double speed = 0;
    if (sp) {
        fm1h_boot(sp, NULL, 0);
        fm1h_run_ms(sp, 1000);
        for (int i = 0; i < 3; i++) fm1h_key(sp, chord[i], 1, 100);
        double ts = now();
        for (int i = 0; i < 441000 / 512; i++) fm1h_pull(sp, buf, 512);
        speed = 10.0 / (now() - ts);
        if (fm1h_halted(sp)) speed = 0;
        fm1h_destroy(sp);
    }
    char log[512];
    fm1h_log_take(h, log, sizeof log);

    /* the optional extras, where the firmware has them */
    if (fm1h_sim1(h)) {
        fm1h_ctl c;
        for (int r = 0; r < FM1H_NROLES; r++) if (fm1h_ctl_info(h, r, &c) >= 0)
            printf("  sim1 role %d: %s %s [%d..%d] = %d (%s)\n", r, c.name, c.text, c.lo, c.hi, c.value, fm1h_ctl_info(h, r, &c) ? "absolute" : "relative");
        printf("  accent %06x\n", fm1h_accent(h));
    }
    if (fm1h_labels_epoch(h)) {
        char lb[20];
        printf("  labels (epoch %u):", fm1h_labels_epoch(h));
        for (int i = 8; i < 22; i++) { int n = fm1h_label(h, i, lb, sizeof lb); printf(" [%s]", n < 0 ? "-" : lb); }
        printf("\n");
    }
    { uint32_t shed = 0, cpu = 0; if (fm1h_stats(h, &shed, &cpu)) printf("  stats: cpu %u%%, shed %u\n", cpu, shed); }
    printf("  master %d, screen changed %u bytes\n", fm1h_master(h), fm1h_screen_changed_bytes(h));

    int ok = !fm1h_halted(h) && lit > 0 && writes2 > writes && (played > 0.001 || idle > 0.001);   /* run.js plus: it makes sound */
    printf("%s halted=%d litPixels=%u lcdWrites=[%u,%u] idleRms=%.4f playedRms=%.4f flash=%zu deviceMs=%u speed=%.1fx realtime%s%s\n",
           ok ? "ok  " : "FAIL", fm1h_halted(h), lit, writes, writes2, idle, played, fl, fm1h_device_ms(h), speed,
           fm1h_halted(h) ? " error=" : "", fm1h_halted(h) ? fm1h_error(h) : "");
    if (log[0]) printf("log: %.200s\n", log);
    fm1h_destroy(h);
    return ok ? 0 : 1;
}
