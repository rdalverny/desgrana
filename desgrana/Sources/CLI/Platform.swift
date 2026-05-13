// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT

// Re-export the correct platform backend so the rest of the CLI stays #if-free.
#if canImport(DesgranaCoreAudioToolbox)
@_exported import DesgranaCoreAudioToolbox
#else
@_exported import DesgranaCoreWav
#endif
