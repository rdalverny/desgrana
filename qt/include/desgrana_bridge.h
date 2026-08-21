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
 * progress_cb: called periodically during splitting with (current_take, total_takes,
 *   fraction, user_data). fraction is in [0, 1]; it is frame-accurate when SE_LOG.BIN
 *   is present, otherwise it advances per completed take. May be NULL.
 *
 * out_silent_skipped: receives the number of silent tracks skipped (nullable).
 * out_kept_mono:      receives the number of mono tracks written (nullable).
 * out_kept_stereo:    receives the number of stereo tracks written (nullable).
 *
 * write_report: when non-zero, a machine-readable JSON report (formats, takes, chosen
 *   extractions with provenance, markers, skipped tracks) is written to
 *   <output_dir>/<prefix>report.json. Off (0) writes nothing.
 * out_report_path: receives the absolute path of the written report (nullable; only
 *   filled when write_report is non-zero and the report was written).
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
    void         (*progress_cb)(int32_t take, int32_t total, double fraction, void *user_data),
    void          *user_data,
    int32_t       *out_silent_skipped, /* nullable */
    int32_t       *out_kept_mono,      /* nullable */
    int32_t       *out_kept_stereo,    /* nullable */
    char          *err_buf,           /* nullable */
    int32_t        err_len,
    int32_t        write_report,       /* 0 = write nothing */
    char          *out_report_path,    /* nullable */
    int32_t        out_report_len
);

/**
 * Fetch the remote version feed and report the result via callback.
 * Designed to be called from a background thread — blocks until the HTTP
 * response arrives (or the request fails).
 *
 * callback is invoked exactly once:
 *   - latest_version / notes / url are non-NULL when a newer version exists.
 *   - All three are NULL when current is up to date or on network error.
 */
void desgrana_check_update(
    const char *current_version,
    void      (*callback)(const char *latest_version,
                          const char *notes,
                          const char *url,
                          void       *user_data),
    void       *user_data
);

/** Which DAW a session file is generated for. */
typedef enum {
    DESGRANA_DAW_REAPER   = 0,  /* generateRPP            → .rpp           */
    DESGRANA_DAW_ARDOUR   = 1,  /* generateArdourSession  → .ardour        */
    DESGRANA_DAW_AUDACITY = 2   /* generateAudacityLOF    → .lof (+ .txt)  */
} desgrana_daw_kind;

/**
 * Generate a DAW session file referencing the WAVs already extracted in output_dir.
 *
 * The sample rate is read from the first WAV's header (RIFF, cross-platform); the
 * caller supplies the session duration (from desgrana_probe). WAVs are taken in
 * sorted filename order, matching the macOS app.
 *
 * session_dir: the original session folder. When non-NULL its SE_LOG is read and
 *   markers are derived from it (position = sample / sample_rate, name "Marker N"),
 *   matching the macOS app. For Audacity these go to a sibling <name>.txt labels
 *   file (LOF carries no markers). Pass NULL to omit markers.
 *
 * out_session_path: receives the absolute path of the generated file (nullable).
 *
 * Returns 0 on success, -1 on error (err_buf filled).
 */
int32_t desgrana_export_daw_session(
    const char *output_dir,
    const char *session_dir,        /* nullable — for SE_LOG markers */
    int32_t     daw_kind,           /* desgrana_daw_kind */
    double      duration_sec,
    char       *out_session_path,   /* nullable */
    int32_t     out_path_len,
    char       *err_buf,            /* nullable */
    int32_t     err_len
);

#ifdef __cplusplus
}
#endif
