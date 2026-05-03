// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Probe a session directory: reads SE_LOG and the first .snap file found.
 * Fills out_channels (0 if unknown), out_duration_sec, and scene_name_buf.
 * Returns 0 on success, -1 if no WAV takes were found (err_buf filled).
 */
int32_t desgrana_probe(
    const char *session_path,
    int32_t    *out_channels,
    double     *out_duration_sec,
    char       *scene_name_buf,   /* nullable */
    int32_t     scene_name_len,
    char       *err_buf,          /* nullable */
    int32_t     err_len
);

/**
 * Split a session into per-channel WAV files.
 *
 * pair_lefts / pair_rights: parallel arrays of 1-based left and right channel numbers,
 *   length pair_count. Pass NULL / 0 to extract all channels as mono.
 *
 * ch_name_keys / ch_name_values: parallel arrays mapping 1-based channel number → name,
 *   length ch_name_count. Pass NULL / 0 to omit channel names from filenames.
 *
 * progress_cb: called after each take with (current_take, total_takes, user_data).
 *   May be NULL. Called from the same thread as desgrana_split.
 *
 * Returns 0 on success, -1 on error (err_buf filled).
 */
int32_t desgrana_split(
    const char    *session_path,
    const char    *output_path,
    const char    *prefix,            /* nullable → empty prefix */
    const int32_t *pair_lefts,        /* nullable */
    const int32_t *pair_rights,       /* nullable */
    int32_t        pair_count,
    const int32_t *ch_name_keys,      /* nullable */
    const char   **ch_name_values,    /* nullable */
    int32_t        ch_name_count,
    void         (*progress_cb)(int32_t take, int32_t total, void *user_data),
    void          *user_data,
    char          *err_buf,           /* nullable */
    int32_t        err_len
);

#ifdef __cplusplus
}
#endif
