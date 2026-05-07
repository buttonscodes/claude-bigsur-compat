/*
 * ICU compatibility shim for macOS Big Sur (11.x)
 *
 * Claude Code's compiled binary links against ICU 72+ (macOS 13+).
 * Big Sur ships ICU 66 which lacks several symbols. This file provides
 * the missing ones:
 *
 *   - ubrk_clone        → real shim via ubrk_safeClone (ICU 66 equivalent)
 *   - ucal_getTimeZoneOffsetFromLocal  → stub (returns U_UNSUPPORTED_ERROR)
 *   - udtitvfmt_formatCalendarToResult → stub
 *   - unumrf_*           → number range formatter stubs
 *   - uplrules_selectForRange          → stub
 *
 * Built as a dylib that re-exports the system libicucore so it can serve
 * as a drop-in replacement with the missing symbols added.
 *
 * Build:
 *   cc -dynamiclib -o libicucore.A.dylib icu_compat.c \
 *      -Wl,-reexport-licucore \
 *      -isysroot $(xcrun --show-sdk-path) \
 *      -install_name "$(pwd)/libicucore.A.dylib" \
 *      -mmacosx-version-min=11.0
 */

#include <stdint.h>
#include <stddef.h>
#include <dlfcn.h>
#include <stdlib.h>

/* ICU error codes */
#define U_ZERO_ERROR        0
#define U_INTERNAL_PROGRAM_ERROR 5
#define U_UNSUPPORTED_ERROR 16

typedef int32_t UErrorCode;
typedef uint16_t UChar;
typedef struct UBreakIterator UBreakIterator;
typedef struct UCalendar UCalendar;
typedef struct UFormattedDateInterval UFormattedDateInterval;
typedef struct UNumberFormatter UNumberFormatter;
typedef struct UNumberRangeFormatter UNumberRangeFormatter;
typedef struct UFormattedNumberRange UFormattedNumberRange;
typedef struct UFormattedValue UFormattedValue;
typedef struct UPluralRules UPluralRules;

/* ── ubrk_clone ─────────────────────────────────────────────────────────
 * Real shim: delegates to ubrk_safeClone which exists in ICU 66.
 * ubrk_clone was added in ICU 69 as a simpler replacement.              */

extern UBreakIterator *ubrk_safeClone(
    const UBreakIterator *bi,
    void *stackBuffer,
    int32_t *pBufferSize,
    UErrorCode *status
);

UBreakIterator *ubrk_clone(const UBreakIterator *bi, UErrorCode *status) {
    return ubrk_safeClone(bi, NULL, NULL, status);
}

/* ── ucal_getTimeZoneOffsetFromLocal ──────────────────────────────────── */

void ucal_getTimeZoneOffsetFromLocal(
    const UCalendar *cal,
    int32_t nonExistingTimeOpt,
    int32_t duplicatedTimeOpt,
    int32_t *rawOffset,
    int32_t *dstOffset,
    UErrorCode *status
) {
    if (status) *status = U_UNSUPPORTED_ERROR;
}

/* ── udtitvfmt_formatCalendarToResult ────────────────────────────────── */

void udtitvfmt_formatCalendarToResult(
    const void *formatter,
    UCalendar *fromCalendar,
    UCalendar *toCalendar,
    UFormattedDateInterval *result,
    UErrorCode *status
) {
    if (status) *status = U_UNSUPPORTED_ERROR;
}

/* ── unumf_openForSkeletonAndLocale : sanitize newer JSC skeletons ───────
 *
 * Newer JavaScriptCore emits the default integer-width skeleton token for
 * integer digit width. ICU 66 rejects that token even though omitting it has
 * the same effect. Retry without that token if the initial open fails.
 */

typedef UNumberFormatter *(*unumf_open_fn)(
    const UChar *skeleton,
    int32_t skeletonLen,
    const char *locale,
    UErrorCode *status
);

typedef void (*unumf_close_fn)(UNumberFormatter *formatter);

UNumberFormatter *unumf_openForSkeletonAndLocale(
    const UChar *skeleton,
    int32_t skeletonLen,
    const char *locale,
    UErrorCode *status
);

static void *icu_handle(void) {
    static void *handle;
    if (!handle)
        handle = dlopen("/usr/lib/libicucore.A.dylib", RTLD_LAZY | RTLD_LOCAL);
    return handle;
}

static unumf_open_fn real_unumf_open(void) {
    static unumf_open_fn fn;
    if (!fn) {
        fn = (unumf_open_fn)dlsym(icu_handle(), "unumf_openForSkeletonAndLocale");
        if (fn == unumf_openForSkeletonAndLocale)
            fn = (unumf_open_fn)dlsym(RTLD_NEXT, "unumf_openForSkeletonAndLocale");
    }
    return fn;
}

static unumf_close_fn real_unumf_close(void) {
    static unumf_close_fn fn;
    if (!fn)
        fn = (unumf_close_fn)dlsym(icu_handle(), "unumf_close");
    return fn;
}

static int uchar_starts_with_ascii(
    const UChar *text,
    int32_t pos,
    int32_t len,
    const char *ascii
) {
    for (int32_t i = 0; ascii[i]; i++) {
        if (pos + i >= len || text[pos + i] != (unsigned char)ascii[i])
            return 0;
    }
    return 1;
}

static UChar *sanitize_number_skeleton(
    const UChar *skeleton,
    int32_t skeletonLen,
    int32_t *outLen,
    int *changed
) {
    UChar *out = (UChar *)malloc(sizeof(UChar) * (size_t)(skeletonLen + 1));
    if (!out)
        return NULL;

    int32_t i = 0;
    int32_t o = 0;
    *changed = 0;

    while (i < skeletonLen) {
        int32_t tokenStart = i;
        int dropLeadingSpace = 0;

        if (skeleton[i] == ' '
            && i + 1 < skeletonLen
            && uchar_starts_with_ascii(skeleton, i + 1, skeletonLen, "integer-width/*")) {
            tokenStart = i + 1;
            dropLeadingSpace = 1;
        }

        if (uchar_starts_with_ascii(skeleton, tokenStart, skeletonLen, "integer-width/*")) {
            if (!dropLeadingSpace && o > 0 && out[o - 1] != ' ')
                out[o++] = ' ';
            i = tokenStart;
            while (i < skeletonLen && skeleton[i] != ' ')
                i++;
            *changed = 1;
            continue;
        }

        out[o++] = skeleton[i++];
    }

    out[o] = 0;
    *outLen = o;
    return out;
}

UNumberFormatter *unumf_openForSkeletonAndLocale(
    const UChar *skeleton,
    int32_t skeletonLen,
    const char *locale,
    UErrorCode *status
) {
    unumf_open_fn open_fn = real_unumf_open();
    if (!open_fn) {
        if (status) *status = U_INTERNAL_PROGRAM_ERROR;
        return NULL;
    }

    UErrorCode localStatus = U_ZERO_ERROR;
    UErrorCode *effectiveStatus = status ? status : &localStatus;
    *effectiveStatus = U_ZERO_ERROR;

    UNumberFormatter *formatter = open_fn(skeleton, skeletonLen, locale, effectiveStatus);
    if (*effectiveStatus <= U_ZERO_ERROR)
        return formatter;

    if (!skeleton)
        return formatter;

    int32_t normalizedLen = skeletonLen;
    if (normalizedLen < 0) {
        normalizedLen = 0;
        while (skeleton[normalizedLen])
            normalizedLen++;
    }

    int changed = 0;
    int32_t sanitizedLen = 0;
    UChar *sanitized = sanitize_number_skeleton(skeleton, normalizedLen, &sanitizedLen, &changed);
    if (!sanitized || !changed) {
        free(sanitized);
        return formatter;
    }

    UErrorCode retryStatus = U_ZERO_ERROR;
    UNumberFormatter *retry = open_fn(sanitized, sanitizedLen, locale, &retryStatus);
    free(sanitized);

    if (retryStatus <= U_ZERO_ERROR && retry) {
        unumf_close_fn close_fn = real_unumf_close();
        if (formatter && close_fn)
            close_fn(formatter);
        *effectiveStatus = retryStatus;
        return retry;
    }

    if (retry) {
        unumf_close_fn close_fn = real_unumf_close();
        if (close_fn)
            close_fn(retry);
    }

    return formatter;
}

/* ── unumrf_* : number range formatter ─────────────────────────────────
 *
 * JavaScriptCore creates a range formatter while constructing
 * Intl.NumberFormat. Returning NULL here makes new Intl.NumberFormat(...)
 * throw "Failed to initialize NumberFormat", even if JS never calls
 * formatRange(). Return stable sentinel pointers for the constructor path;
 * the actual format-range operations still report U_UNSUPPORTED_ERROR.
 */

static char unumrf_sentinel_fmt;
static char unumrf_sentinel_result;
#define UNUMRF_FMT_SENTINEL    ((UNumberRangeFormatter *)&unumrf_sentinel_fmt)
#define UNUMRF_RESULT_SENTINEL ((UFormattedNumberRange *)&unumrf_sentinel_result)

UNumberRangeFormatter *unumrf_openForSkeletonWithCollapseAndIdentityFallback(
    const UChar *skeleton,
    int32_t skeletonLen,
    int32_t collapse,
    int32_t identityFallback,
    const char *locale,
    void *perror,
    UErrorCode *status
) {
    if (status) *status = U_ZERO_ERROR;
    return UNUMRF_FMT_SENTINEL;
}

void unumrf_close(UNumberRangeFormatter *fmt) {
    (void)fmt;
}

UFormattedNumberRange *unumrf_openResult(UErrorCode *status) {
    if (status) *status = U_ZERO_ERROR;
    return UNUMRF_RESULT_SENTINEL;
}

void unumrf_closeResult(UFormattedNumberRange *res) {
    (void)res;
}

void unumrf_formatDoubleRange(
    const UNumberRangeFormatter *fmt,
    double first,
    double second,
    UFormattedNumberRange *result,
    UErrorCode *status
) {
    if (status) *status = U_UNSUPPORTED_ERROR;
}

void unumrf_formatDecimalRange(
    const UNumberRangeFormatter *fmt,
    const char *first, int32_t firstLen,
    const char *second, int32_t secondLen,
    UFormattedNumberRange *result,
    UErrorCode *status
) {
    if (status) *status = U_UNSUPPORTED_ERROR;
}

const UFormattedValue *unumrf_resultAsValue(
    const UFormattedNumberRange *result,
    UErrorCode *status
) {
    if (status) *status = U_UNSUPPORTED_ERROR;
    return NULL;
}

/* ── uplrules_selectForRange ─────────────────────────────────────────── */

int32_t uplrules_selectForRange(
    const UPluralRules *rules,
    const UFormattedNumberRange *number,
    UChar *keyword,
    int32_t capacity,
    UErrorCode *status
) {
    if (status) *status = U_UNSUPPORTED_ERROR;
    return 0;
}
