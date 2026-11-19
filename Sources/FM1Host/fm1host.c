/* fm1host.c: see include/fm1host.h. Ported from FM-1 Pocket Player's src/rfm1.js (MIT, Jake Handy). */
#include "fm1host.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "wasm3.h"
#include "m3_env.h"          /* the module's import list (wasm3 internals) */

#define FS 44100
#define BLOCK 128
#define NCOL 11
#define NLINE 4
#define RING (16384 * 2)
#define LOGCAP 8192
#define ABI 6
#define ABI_MIN 5
#define WASM_STACK (1024 * 1024)

/* the offsets a wasm32 build of fm1core.h gives (rfm1_layout indexes 0..33); checked, not assumed */
static const uint32_t LAYOUT[34] = { 115384, 0, 4, 8, 12, 16, 44, 48, 75, 102, 146, 148, 115348, 115352, 115366,
    115373, 115380, 192, 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 92, 96, 100, 104, 108, 188 };
enum { P_KEYS = 1, P_BUTTONS, P_KEYS_TAP, P_BUTTONS_TAP, P_ENC, P_MASTER, P_KEY_VEL, P_KEY_LEAN, P_LED,
       P_LED_PLAY_GREEN, P_LCD, P_LCD_WRITES, P_BTN_ID, P_ENC_ID, P_ENC_DIR, P_READY };
enum { C_ABI = 18, C_ID, C_NAME, C_VERSION, C_SOURCE_URL, C_FAMILY, C_LICENSE, C_GATED, C_FLASH_SIZE,
       C_BUTTON_NAMES, C_PARAMS, C_NPARAMS, C_PANEL, C_KEYMAP, C_OPTIONS, C_CREDITS };

static const char *LABELS[FM1H_NBUTTONS] = { "FX", "SEL", "ENV", "LFO", "EDIT", "GLO", "HOME", "SAVE", "ARP", "SEQ",
    "PLAY", "REC", "OCT-", "OCT+" };

enum { F_VERSION, F_GET, F_LAYOUT, F_ALLOC, F_OPTIONS, F_BOOT_OPTIONS, F_INIT, F_TICK, F_FRAME, F_IDLE, F_AUDIO,
       F_MIDI_IN, F_FLASH_STAGE, F_FLASH, F_FLASH_DIRTY, F_FLASH_SYNC, F_SHUTDOWN, F_INITIALIZE, F_COUNT };
static const char *FNAMES[F_COUNT] = { "rfm1_version", "rfm1_get", "rfm1_layout", "rfm1_alloc", "rfm1_options",
    "rfm1_boot_options", "rfm1_init", "rfm1_tick", "rfm1_frame", "rfm1_idle", "rfm1_audio", "rfm1_midi_in",
    "rfm1_flash_stage", "rfm1_flash", "rfm1_flash_dirty", "rfm1_flash_sync", "rfm1_shutdown", "_initialize" };
/* exports a module must have (memory is checked separately) */
static const int REQUIRED[] = { F_VERSION, F_GET, F_LAYOUT, F_ALLOC, F_OPTIONS, F_INIT, F_TICK, F_FRAME, F_IDLE,
    F_AUDIO, F_FLASH_STAGE, F_FLASH, F_FLASH_DIRTY };

struct fm1h {
    pthread_mutex_t lock;
    uint8_t *wasm;
    IM3Environment env;
    IM3Runtime rt;
    IM3Module mod;
    IM3Function fn[F_COUNT];

    int halted, exit_code;
    char error[256];
    char log[LOGCAP];
    size_t loglen;

    uint32_t d, panel, keymap, flash_size;
    int abi;
    char *info[7];
    char *button_names[FM1H_NBUTTONS];

    uint8_t btn_id[FM1H_NBUTTONS], enc_id[FM1H_NROLES];
    int8_t enc_dir[FM1H_NROLES];
    int btn_led[FM1H_NBUTTONS], key_led[FM1H_NKEYS];

    uint32_t ms;
    uint64_t blocks;
    uint32_t abuf;
    float ring[RING];
    uint64_t rw, rr;
};

/* ---- memory ---- */
static uint8_t *mem(fm1h *h, uint32_t *size) {
    uint32_t n = 0;
    uint8_t *m = m3_GetMemory(h->rt, &n, 0);
    if (size) *size = n;
    return m;
}
static int inmem(fm1h *h, uint32_t p, uint32_t len) {
    uint32_t n;
    return mem(h, &n) && (uint64_t)p + len <= n;
}
static uint32_t rd32(fm1h *h, uint32_t p) {
    uint32_t v = 0;
    if (inmem(h, p, 4)) memcpy(&v, mem(h, NULL) + p, 4);   /* wasm and Apple Silicon are both little-endian */
    return v;
}
static void wr32(fm1h *h, uint32_t p, uint32_t v) { if (inmem(h, p, 4)) memcpy(mem(h, NULL) + p, &v, 4); }
static uint8_t rd8(fm1h *h, uint32_t p) { return inmem(h, p, 1) ? mem(h, NULL)[p] : 0; }
static void wr8(fm1h *h, uint32_t p, uint8_t v) { if (inmem(h, p, 1)) mem(h, NULL)[p] = v; }
static char *cstr(fm1h *h, uint32_t p, uint32_t max) {
    uint32_t n, e;
    uint8_t *m = mem(h, &n);
    if (!p || !m || p >= n) return strdup("");
    for (e = p; e < n && e - p < max && m[e]; e++) {}
    char *s = malloc(e - p + 1);
    if (!s) return strdup("");
    memcpy(s, m + p, e - p);
    s[e - p] = 0;
    return s;
}
static uint32_t pp(fm1h *h, int k) { return h->panel + LAYOUT[k]; }

/* ---- calls into the module ---- */
static void fail(fm1h *h, int code, const char *why) {
    if (h->halted) return;
    h->halted = code;
    snprintf(h->error, sizeof h->error, "%s", why ? why : "stopped");
}
/* calls export f with up to four i32 arguments; returns its i32 result (0 if none, or if the firmware stopped) */
static int32_t call(fm1h *h, int f, int argc, int32_t a0, int32_t a1, int32_t a2, int32_t a3) {
    IM3Function fn = h->fn[f];
    if (!fn || h->halted) return 0;
    int32_t args[4] = { a0, a1, a2, a3 };
    const void *ptrs[4] = { &args[0], &args[1], &args[2], &args[3] };
    M3Result r = m3_Call(fn, (uint32_t)argc, ptrs);
    if (r) {
        if (r == m3Err_trapExit) fail(h, 0x100 | (h->exit_code & 0xff), "The firmware stopped itself.");
        else {
            M3ErrorInfo info;
            char msg[200];
            m3_GetErrorInfo(h->rt, &info);
            snprintf(msg, sizeof msg, "%s in %s: %s", FNAMES[f], r, info.message ? info.message : "");
            fail(h, 0x1ff, msg);
        }
        return 0;
    }
    if (m3_GetRetCount(fn) == 0) return 0;
    int32_t ret = 0;
    const void *rp[1] = { &ret };
    if (m3_GetResults(fn, 1, rp)) return 0;
    return ret;
}
#define CALL0(h, f) call(h, f, 0, 0, 0, 0, 0)
#define CALL1(h, f, a) call(h, f, 1, a, 0, 0, 0)
#define CALL2(h, f, a, b) call(h, f, 2, a, b, 0, 0)
#define CALL3(h, f, a, b, c) call(h, f, 3, a, b, c, 0)
#define CALL4(h, f, a, b, c, d) call(h, f, 4, a, b, c, d)

/* ---- WASI: the only imports a module may have. stdout and stderr go to the log; the rest do nothing ---- */
static void logtext(fm1h *h, const char *s, size_t n) {
    if (n > LOGCAP - 1) { s += n - (LOGCAP - 1); n = LOGCAP - 1; }
    if (h->loglen + n > LOGCAP - 1) {
        size_t drop = h->loglen + n - (LOGCAP - 1);
        memmove(h->log, h->log + drop, h->loglen - drop);
        h->loglen -= drop;
    }
    memcpy(h->log + h->loglen, s, n);
    h->loglen += n;
}
static m3ApiRawFunction(wasi_fd_write) {
    m3ApiReturnType(int32_t);
    m3ApiGetArg(int32_t, fd);
    m3ApiGetArg(uint32_t, iovs);
    m3ApiGetArg(uint32_t, n);
    m3ApiGetArg(uint32_t, nwritten);
    fm1h *h = (fm1h *)_ctx->userdata;
    uint32_t size = m3_GetMemorySize(runtime), total = 0, i;
    uint8_t *m = (uint8_t *)_mem;
    for (i = 0; i < n; i++) {
        uint32_t p, l, at = iovs + i * 8;
        if ((uint64_t)at + 8 > size) m3ApiTrap(m3Err_trapOutOfBoundsMemoryAccess);
        memcpy(&p, m + at, 4);
        memcpy(&l, m + at + 4, 4);
        if ((uint64_t)p + l > size) m3ApiTrap(m3Err_trapOutOfBoundsMemoryAccess);
        if (fd == 1 || fd == 2) logtext(h, (const char *)m + p, l);
        total += l;
    }
    if ((uint64_t)nwritten + 4 > size) m3ApiTrap(m3Err_trapOutOfBoundsMemoryAccess);
    memcpy(m + nwritten, &total, 4);
    m3ApiReturn(fd == 1 || fd == 2 ? 0 : 8);
}
static m3ApiRawFunction(wasi_badf) { m3ApiReturnType(int32_t); m3ApiReturn(8); }
static m3ApiRawFunction(wasi_nosys) { m3ApiReturnType(int32_t); m3ApiReturn(52); }
static m3ApiRawFunction(wasi_clock_time_get) {
    m3ApiReturnType(int32_t);
    m3ApiGetArg(int32_t, id);
    m3ApiGetArg(int64_t, precision);
    m3ApiGetArg(uint32_t, out);
    (void)id; (void)precision;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uint64_t ns = (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
    if ((uint64_t)out + 8 > m3_GetMemorySize(runtime)) m3ApiTrap(m3Err_trapOutOfBoundsMemoryAccess);
    memcpy((uint8_t *)_mem + out, &ns, 8);
    m3ApiReturn(0);
}
static m3ApiRawFunction(wasi_proc_exit) {
    m3ApiGetArg(int32_t, code);
    fm1h *h = (fm1h *)_ctx->userdata;
    h->exit_code = code;            /* call() turns this into 0x1xx */
    m3ApiTrap(m3Err_trapExit);
}

static const void *wasi_for(const char *name) {
    if (!strcmp(name, "fd_write")) return (const void *)wasi_fd_write;
    if (!strcmp(name, "fd_read") || !strcmp(name, "fd_close") || !strcmp(name, "fd_seek") ||
        !strcmp(name, "fd_fdstat_get")) return (const void *)wasi_badf;
    if (!strcmp(name, "clock_time_get")) return (const void *)wasi_clock_time_get;
    if (!strcmp(name, "proc_exit")) return (const void *)wasi_proc_exit;
    return (const void *)wasi_nosys;        /* ENOSYS: not in the format */
}

/* ---- loading ---- */
static fm1h *bail(fm1h *h, char *err, size_t errlen, const char *msg) {
    if (err && errlen) snprintf(err, errlen, "%s", msg);
    fm1h_destroy(h);
    return NULL;
}

fm1h *fm1h_create(const uint8_t *wasm, size_t len, char *err, size_t errlen) {
    char msg[300];
    M3Result r;
    uint32_t i;
    fm1h *h = calloc(1, sizeof *h);
    if (!h) return bail(NULL, err, errlen, "Out of memory.");
    pthread_mutex_init(&h->lock, NULL);
    if (len < 8 || wasm[0] != 0 || wasm[1] != 'a' || wasm[2] != 's' || wasm[3] != 'm')
        return bail(h, err, errlen, "This is not a WebAssembly module, so it is not an .rfm1 file.");
    h->wasm = malloc(len);                  /* wasm3 keeps pointers into the bytes */
    if (!h->wasm) return bail(h, err, errlen, "Out of memory.");
    memcpy(h->wasm, wasm, len);

    h->env = m3_NewEnvironment();
    h->rt = h->env ? m3_NewRuntime(h->env, WASM_STACK, h) : NULL;
    if (!h->rt) return bail(h, err, errlen, "Could not start the WebAssembly interpreter.");
    IM3Module mod = NULL;
    if ((r = m3_ParseModule(h->env, &mod, h->wasm, (uint32_t)len))) {
        snprintf(msg, sizeof msg, "The firmware could not be read: %s", r);
        return bail(h, err, errlen, msg);
    }
    if ((r = m3_LoadModule(h->rt, mod))) {
        m3_FreeModule(mod);
        snprintf(msg, sizeof msg, "The firmware could not be loaded: %s", r);
        return bail(h, err, errlen, msg);
    }
    h->mod = mod;

    /* imports: only wasi_snapshot_preview1, as the format says */
    for (i = 0; i < mod->numFuncImports; i++) {
        M3Function *f = &mod->functions[i];
        const char *m = f->import.moduleUtf8 ? f->import.moduleUtf8 : "", *n = f->import.fieldUtf8 ? f->import.fieldUtf8 : "";
        if (strcmp(m, "wasi_snapshot_preview1")) {
            snprintf(msg, sizeof msg, "The module imports %s.%s, which the .rfm1 format does not allow.", m, n);
            return bail(h, err, errlen, msg);
        }
        if (f->compiled) continue;          /* the same import twice: already linked */
        r = m3_LinkRawFunctionEx(mod, m, n, NULL, wasi_for(n), h);
        if (r && r != m3Err_functionLookupFailed) {
            snprintf(msg, sizeof msg, "Could not link %s: %s", n, r);
            return bail(h, err, errlen, msg);
        }
    }

    for (i = 0; i < F_COUNT; i++) if (m3_FindFunction(&h->fn[i], h->rt, FNAMES[i])) h->fn[i] = NULL;
    msg[0] = 0;
    for (i = 0; i < sizeof REQUIRED / sizeof REQUIRED[0]; i++) if (!h->fn[REQUIRED[i]]) {
        if (!msg[0]) strcpy(msg, "The module is missing");
        strncat(msg, " ", sizeof msg - strlen(msg) - 1);
        strncat(msg, FNAMES[REQUIRED[i]], sizeof msg - strlen(msg) - 1);
    }
    if (msg[0]) { strncat(msg, ".", sizeof msg - strlen(msg) - 1); return bail(h, err, errlen, msg); }
    if (!mem(h, NULL)) return bail(h, err, errlen, "The module has no memory.");

    /* compile every function now, so the audio thread never compiles */
    if ((r = m3_CompileModule(mod))) {
        snprintf(msg, sizeof msg, "The firmware could not be compiled: %s", r);
        return bail(h, err, errlen, msg);
    }
    if ((r = m3_RunStart(mod))) {
        snprintf(msg, sizeof msg, "The firmware's start function failed: %s", r);
        return bail(h, err, errlen, msg);
    }

    /* the checks rfm1.js makes */
    if (h->fn[F_INITIALIZE]) CALL0(h, F_INITIALIZE);
    int32_t v = CALL0(h, F_VERSION);
    if (h->halted) { snprintf(msg, sizeof msg, "The firmware stopped while starting: %s", h->error); return bail(h, err, errlen, msg); }
    if (v != 1) {
        snprintf(msg, sizeof msg, "The module says it is .rfm1 version %d; this player reads version 1.", v);
        return bail(h, err, errlen, msg);
    }
    h->d = (uint32_t)CALL1(h, F_GET, ABI);
    if (!h->d) h->d = (uint32_t)CALL1(h, F_GET, ABI_MIN);
    if (!h->d) return bail(h, err, errlen, "The module does not speak fm1core ABI 6 (or 5).");
    h->abi = (int)rd32(h, h->d);
    for (i = 0; i < 34; i++) {
        uint32_t lv = (uint32_t)CALL1(h, F_LAYOUT, (int32_t)i);
        if (i == 17 && lv == 188 && h->abi == 5) continue;     /* ABI 5: no credits */
        if (i == 33 && h->abi == 5) continue;
        if (lv != LAYOUT[i]) {
            snprintf(msg, sizeof msg, "The module's fm1core layout differs from ABI 6 at entry %u (%u, expected %u).", i, lv, LAYOUT[i]);
            return bail(h, err, errlen, msg);
        }
    }
    h->panel = rd32(h, h->d + LAYOUT[C_PANEL]);
    h->keymap = rd32(h, h->d + LAYOUT[C_KEYMAP]);
    h->flash_size = rd32(h, h->d + LAYOUT[C_FLASH_SIZE]);
    static const int infoField[7] = { C_ID, C_NAME, C_VERSION, C_SOURCE_URL, C_FAMILY, C_LICENSE, C_CREDITS };
    for (i = 0; i < 7; i++) {
        if (i == FM1H_INFO_CREDITS && h->abi < 6) { h->info[i] = strdup(""); continue; }
        h->info[i] = cstr(h, rd32(h, h->d + LAYOUT[infoField[i]]), i == FM1H_INFO_CREDITS ? 65536 : 4096);
    }
    for (i = 0; i < FM1H_NBUTTONS; i++) {
        char *s = cstr(h, rd32(h, h->d + LAYOUT[C_BUTTON_NAMES] + 4 * i), 64);
        if (!s[0]) { free(s); s = strdup(LABELS[i]); }
        h->button_names[i] = s;
    }
    if (!h->panel || !inmem(h, h->panel, LAYOUT[0])) return bail(h, err, errlen, "The module has no panel.");
    return h;
}

void fm1h_destroy(fm1h *h) {
    int i;
    if (!h) return;
    if (h->rt) m3_FreeRuntime(h->rt);      /* frees the loaded module too */
    if (h->env) m3_FreeEnvironment(h->env);
    free(h->wasm);
    for (i = 0; i < 7; i++) free(h->info[i]);
    for (i = 0; i < FM1H_NBUTTONS; i++) free(h->button_names[i]);
    pthread_mutex_destroy(&h->lock);
    free(h);
}

int fm1h_abi(fm1h *h) { return h->abi; }
const char *fm1h_info(fm1h *h, int field) {
    return field >= 0 && field < 7 && h->info[field] ? h->info[field] : "";
}
const char *fm1h_button_name(fm1h *h, int label) {
    return label >= 0 && label < FM1H_NBUTTONS && h->button_names[label] ? h->button_names[label] : "";
}
uint32_t fm1h_flash_size(fm1h *h) { return h->flash_size; }

/* ---- power on ---- */
static void read_map(fm1h *h) {
    int pos[64], i, r, c;
    for (i = 0; i < 64; i++) pos[i] = -1;
    for (i = 0; i < FM1H_NBUTTONS; i++) h->btn_id[i] = rd8(h, pp(h, P_BTN_ID) + i);
    for (i = 0; i < FM1H_NROLES; i++) {
        h->enc_id[i] = rd8(h, pp(h, P_ENC_ID) + i);
        h->enc_dir[i] = (int8_t)rd8(h, pp(h, P_ENC_DIR) + i);
        if (!h->enc_dir[i]) h->enc_dir[i] = 1;
    }
    if (h->keymap) for (r = 1; r <= NLINE; r++) for (c = 0; c < NCOL; c++) {
        int id = (int8_t)rd8(h, h->keymap + r * NCOL + c);
        if (id >= 0 && id < 64) pos[id] = c * NLINE + (r - 1);
    }
    for (i = 0; i < FM1H_NBUTTONS; i++) h->btn_led[i] = h->btn_id[i] < 64 ? pos[h->btn_id[i]] : -1;
    for (i = 0; i < FM1H_NKEYS; i++) h->key_led[i] = pos[14 + i];
}

void fm1h_boot(fm1h *h, const uint8_t *flash, size_t len) {
    static const char staged[] = "fm1core:staged";
    pthread_mutex_lock(&h->lock);
    if (flash && len) {
        uint32_t n = (uint32_t)(h->flash_size && len > h->flash_size ? h->flash_size : len);
        uint32_t p = (uint32_t)CALL1(h, F_ALLOC, (int32_t)n);
        if (p && inmem(h, p, n)) {
            memcpy(mem(h, NULL) + p, flash, n);
            CALL2(h, F_FLASH_STAGE, (int32_t)p, (int32_t)n);
        } else CALL2(h, F_FLASH_STAGE, 0, 0);
    } else CALL2(h, F_FLASH_STAGE, 0, 0);
    uint32_t path = (uint32_t)CALL1(h, F_ALLOC, (int32_t)sizeof staged);
    if (path && inmem(h, path, sizeof staged)) memcpy(mem(h, NULL) + path, staged, sizeof staged);
    CALL4(h, F_OPTIONS, (int32_t)path, 0, 0, 1);
    if (h->fn[F_BOOT_OPTIONS]) CALL3(h, F_BOOT_OPTIONS, -1, 0, -1);
    wr8(h, pp(h, P_READY), 2);
    CALL1(h, F_INIT, 0);
    read_map(h);
    h->ms = 0;
    h->blocks = 0;
    h->rw = h->rr = 0;
    pthread_mutex_unlock(&h->lock);
}

/* ---- the clock: one device millisecond at a time, as the ABI wants ---- */
static void run_ms(fm1h *h, int n) {
    int k, i;
    for (k = 0; k < n && !h->halted; k++) {
        CALL1(h, F_TICK, (int32_t)h->ms);
        if (h->ms % 15 == 0) CALL0(h, F_FRAME); else CALL0(h, F_IDLE);
        uint64_t due = ((uint64_t)h->ms + 1) * FS / (1000 * BLOCK);
        while (h->blocks < due && !h->halted) {
            if (!h->abuf) h->abuf = (uint32_t)CALL1(h, F_ALLOC, BLOCK * 4);
            if (!h->abuf) { fail(h, 0x1fe, "The firmware gave no room for its audio."); break; }
            CALL2(h, F_AUDIO, (int32_t)h->abuf, BLOCK);
            if (!inmem(h, h->abuf, BLOCK * 4)) { fail(h, 0x1fe, "The audio buffer is outside memory."); break; }
            const uint8_t *src = mem(h, NULL) + h->abuf;
            for (i = 0; i < BLOCK * 2; i++) {
                int16_t s;
                memcpy(&s, src + 2 * i, 2);
                h->ring[h->rw++ % RING] = s / 32768.0f;
            }
            if (h->rw - h->rr > RING) h->rr = h->rw - RING;
            h->blocks++;
        }
        h->ms++;
    }
}
void fm1h_run_ms(fm1h *h, int ms) {
    pthread_mutex_lock(&h->lock);
    run_ms(h, ms);
    pthread_mutex_unlock(&h->lock);
}
void fm1h_pull(fm1h *h, float *out, int frames) {
    int guard = 0, i;
    pthread_mutex_lock(&h->lock);
    while ((int64_t)((h->rw - h->rr) >> 1) < frames && !h->halted && guard++ < 250) run_ms(h, 1);
    for (i = 0; i < frames * 2; i++) out[i] = h->rw > h->rr ? h->ring[h->rr++ % RING] : 0.0f;
    pthread_mutex_unlock(&h->lock);
}
uint32_t fm1h_device_ms(fm1h *h) { return h->ms; }

/* ---- the panel ---- */
void fm1h_key(fm1h *h, int k, int down, int vel) {
    if (k < 0 || k >= FM1H_NKEYS) return;
    pthread_mutex_lock(&h->lock);
    uint32_t m = rd32(h, pp(h, P_KEYS));
    if (down) {
        wr8(h, pp(h, P_KEY_VEL) + (uint32_t)k, (uint8_t)(vel ? (vel < 1 ? 1 : vel > 127 ? 127 : vel) : 0));
        m |= 1u << k;
    } else m &= ~(1u << k);
    wr32(h, pp(h, P_KEYS), m);
    pthread_mutex_unlock(&h->lock);
}
void fm1h_button(fm1h *h, int label, int down) {
    if (label < 0 || label >= FM1H_NBUTTONS) return;
    pthread_mutex_lock(&h->lock);
    uint32_t bit = h->btn_id[label], m = rd32(h, pp(h, P_BUTTONS));
    if (bit < 32) {
        m = down ? (m | (1u << bit)) : (m & ~(1u << bit));
        wr32(h, pp(h, P_BUTTONS), m);
    }
    pthread_mutex_unlock(&h->lock);
}
void fm1h_turn(fm1h *h, int role, int detents) {
    if (role < 0 || role >= FM1H_NROLES || !detents) return;
    pthread_mutex_lock(&h->lock);
    uint32_t a = pp(h, P_ENC) + 4u * h->enc_id[role];
    if (h->enc_id[role] < FM1H_NROLES) wr32(h, a, (uint32_t)((int32_t)rd32(h, a) + detents * h->enc_dir[role]));
    pthread_mutex_unlock(&h->lock);
}
void fm1h_set_master(fm1h *h, int v) {
    pthread_mutex_lock(&h->lock);
    wr32(h, pp(h, P_MASTER), (uint32_t)(v < 0 ? 0 : v > 1023 ? 1023 : v));
    pthread_mutex_unlock(&h->lock);
}
int fm1h_midi(fm1h *h, uint8_t status, uint8_t d1, uint8_t d2) {
    if (!h->fn[F_MIDI_IN]) return 0;
    uint32_t pkt = ((status >> 4) & 0xfu) | ((uint32_t)status << 8) | ((uint32_t)d1 << 16) | ((uint32_t)d2 << 24);
    pthread_mutex_lock(&h->lock);
    int r = CALL1(h, F_MIDI_IN, (int32_t)pkt);
    pthread_mutex_unlock(&h->lock);
    return r;
}

/* the screen: 240 x 240 RGB565, high byte first */
uint32_t fm1h_screen_rgba(fm1h *h, uint8_t *out) {
    uint32_t n = FM1H_SCREEN_W * FM1H_SCREEN_H, i, w;
    pthread_mutex_lock(&h->lock);
    w = rd32(h, pp(h, P_LCD_WRITES));
    if (inmem(h, pp(h, P_LCD), n * 2)) {
        const uint8_t *s = mem(h, NULL) + pp(h, P_LCD);
        for (i = 0; i < n; i++) {
            uint16_t px = (uint16_t)((s[2 * i] << 8) | s[2 * i + 1]);
            uint8_t r = (px >> 11) & 31, g = (px >> 5) & 63, b = px & 31;
            out[4 * i] = (uint8_t)((r << 3) | (r >> 2));
            out[4 * i + 1] = (uint8_t)((g << 2) | (g >> 4));
            out[4 * i + 2] = (uint8_t)((b << 3) | (b >> 2));
            out[4 * i + 3] = 255;
        }
    } else memset(out, 0, n * 4);
    pthread_mutex_unlock(&h->lock);
    return w;
}
uint32_t fm1h_lcd_writes(fm1h *h) {
    pthread_mutex_lock(&h->lock);
    uint32_t w = rd32(h, pp(h, P_LCD_WRITES));
    pthread_mutex_unlock(&h->lock);
    return w;
}
void fm1h_leds(fm1h *h, uint8_t buttons[FM1H_NBUTTONS], uint8_t keys[FM1H_NKEYS], uint8_t *play_green) {
    int i;
    pthread_mutex_lock(&h->lock);
    uint32_t base = pp(h, P_LED);
    for (i = 0; i < FM1H_NBUTTONS; i++) buttons[i] = h->btn_led[i] < 0 ? 0 : rd8(h, base + (uint32_t)h->btn_led[i]);
    for (i = 0; i < FM1H_NKEYS; i++) keys[i] = h->key_led[i] < 0 ? 0 : rd8(h, base + (uint32_t)h->key_led[i]);
    if (play_green) *play_green = rd8(h, pp(h, P_LED_PLAY_GREEN));
    pthread_mutex_unlock(&h->lock);
}

/* ---- the flash image ---- */
uint32_t fm1h_flash_dirty(fm1h *h) {
    pthread_mutex_lock(&h->lock);
    uint32_t d = (uint32_t)CALL0(h, F_FLASH_DIRTY);
    pthread_mutex_unlock(&h->lock);
    return d;
}
size_t fm1h_flash_copy(fm1h *h, int sync, uint8_t *out, size_t cap) {
    size_t n = 0;
    pthread_mutex_lock(&h->lock);
    if (sync && h->fn[F_FLASH_SYNC]) CALL0(h, F_FLASH_SYNC);
    uint32_t p = (uint32_t)CALL0(h, F_FLASH);
    if (p && h->flash_size && inmem(h, p, h->flash_size)) {
        n = h->flash_size < cap ? h->flash_size : cap;
        memcpy(out, mem(h, NULL) + p, n);
    }
    pthread_mutex_unlock(&h->lock);
    return n;
}
void fm1h_shutdown(fm1h *h) {
    pthread_mutex_lock(&h->lock);
    if (h->fn[F_SHUTDOWN]) CALL0(h, F_SHUTDOWN);
    pthread_mutex_unlock(&h->lock);
}

int fm1h_halted(fm1h *h) { return h->halted; }
const char *fm1h_error(fm1h *h) { return h->error; }
size_t fm1h_log_take(fm1h *h, char *out, size_t cap) {
    if (!cap) return 0;
    pthread_mutex_lock(&h->lock);
    size_t n = h->loglen < cap - 1 ? h->loglen : cap - 1;
    memcpy(out, h->log, n);
    out[n] = 0;
    h->loglen = 0;
    pthread_mutex_unlock(&h->lock);
    return n;
}
