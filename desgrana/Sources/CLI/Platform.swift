// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT

// Re-export the correct platform backend so the rest of the CLI stays #if-free.
#if canImport(DesgranaCoreMac)
@_exported import DesgranaCoreMac
#else
@_exported import DesgranaCoreLinux
#endif
