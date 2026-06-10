/*
 * libtagfix.c — Disable Android bionic software TBI heap pointer tagging
 *
 * Background:
 *   Android bionic (API 11+) enables software Tag-Based Isolation (TBI) heap
 *   tagging by default: every malloc'd pointer has 0xB4 in its top byte.
 *   Bun/JavaScriptCore uses the top byte of pointers for NaN-boxing, zeroing it.
 *   When JSC later frees such a pointer, bionic's MaybeUntagAndCheckPointer sees
 *   a tag mismatch (0xB4 expected, 0x00 present) and calls async_safe_fatal:
 *     "Pointer tag for 0x... was truncated"
 *   This causes a SIGABRT at any free() after JSC allocates a JIT region.
 *
 * Fix:
 *   The TBI → NONE downgrade is officially supported by bionic.
 *   mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE) must
 *   run *inside* the target process before JSC initialises — an LD_PRELOAD
 *   constructor is the correct hook. execv-based wrappers don't work because
 *   execv resets the tagging level on the new process image.
 *
 * This shared object is LD_PRELOAD'd by the opencode wrapper script.
 * On non-Android or Android builds with tagging already NONE, mallopt is a
 * no-op, so this is safe to ship universally.
 */

#include <malloc.h>

#ifndef M_BIONIC_SET_HEAP_TAGGING_LEVEL
#define M_BIONIC_SET_HEAP_TAGGING_LEVEL (-204)
#endif

#ifndef M_HEAP_TAGGING_LEVEL_NONE
#define M_HEAP_TAGGING_LEVEL_NONE 0
#endif

__attribute__((constructor))
static void disable_heap_tagging(void) {
    mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE);
}
