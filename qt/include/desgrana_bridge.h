// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Maximum bytes per channel name slot (including null terminator). */
#define DESGRANA_CH_NAME_MAX 64

/**
 * Probe a session directory: reads SE_LOG and the first .snap file found.
 * Fills out_channels (0 if unknown), out_duration_sec, and scene_name_buf.
 *
 * Snap stereo pairs (all nullable — pass NULL/0 to skip):
 *   out_pair_lefts / out_pair_rights: caller-allocated int32 arrays, capacity = pair_capacity.
 *   out_pair_count: receives the number of pairs written.
 *
 * Snap channel names (all nullable — pass NULL/0 to skip):
 *   out_ch_keys: caller-allocated int32 array of 1-based channel numbers.
 *   out_ch_names: flat buffer; each slot is DESGRANA_CH_NAME_MAX bytes, null-terminated.
 *   out_ch_count: receives the number of entries written.
 *
 * Returns 0 on success, -1 if no WAV takes were found (err_buf filled).
 */
int32_t desgrana_probe(
    const char *session_path,
    int32_t    *out_channels,
    double     *out_duration_sec,
    char       *scene_name_buf,   /* nullable */
    int32_t     scene_name_len,
    int32_t    *out_pair_lefts,   /* nullable */
    int32_t    *out_pair_rights,  /* nullable */
    int32_t     pair_capacity,
    int32_t    *out_pair_count,   /* nullable */
    int32_t    *out_ch_keys,      /* nullable */
    char       *out_ch_names,     /* nullable: flat, DESGRANA_CH_NAME_MAX bytes per slot */
    int32_t     ch_capacity,
    int32_t    *out_ch_count,     /* nullable */
    char       *err_buf,          /* nullable */
    int32_t     err_len,
    int32_t    *out_snap_found    /* nullable — 1 if a snap was loaded, 0 otherwise */
);

/**
 * Parse a single .snap or .scn file and fill snap metadata.
 * channel_count is inferred from the highest channel key in the snap.
 * Returns 0 on success, -1 if the file cannot be parsed.
 */
int32_t desgrana_load_snap(
    const char *snap_path,
    char       *scene_name_buf,  /* nullable */
    int32_t     scene_name_len,
    int32_t    *out_pair_lefts,  /* nullable */
    int32_t    *out_pair_rights, /* nullable */
    int32_t     pair_capacity,
    int32_t    *out_pair_count,  /* nullable */
    int32_t    *out_ch_keys,     /* nullable */
    char       *out_ch_names,    /* nullable: flat, DESGRANA_CH_NAME_MAX bytes per slot */
    int32_t     ch_capacity,
    int32_t    *out_ch_count     /* nullable */
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
 * out_silent_skipped: receives the number of silent tracks skipped (nullable).
 * out_kept_mono:      receives the number of mono tracks written (nullable).
 * out_kept_stereo:    receives the number of stereo tracks written (nullable).
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
    int32_t       *out_silent_skipped, /* nullable */
    int32_t       *out_kept_mono,      /* nullable */
    int32_t       *out_kept_stereo,    /* nullable */
    char          *err_buf,           /* nullable */
    int32_t        err_len
);

#ifdef __cplusplus
}
#endif
