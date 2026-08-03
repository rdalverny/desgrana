// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT

public enum Constants {
    /// Sizing of the interleaved read block used by the splitter.
    public enum Block {
        /// Target size of the interleaved read buffer.
        ///
        /// The split is dominated by one `write()` per output track per block, so a
        /// larger block means fewer syscalls. Measured on a 32-channel session, the
        /// gain saturates at about 2 MB: below it the syscall count still hurts,
        /// above it nothing improves and the working set starts falling out of L2
        /// (an 8 MB buffer doubled CPU time, 16 MB quintupled it).
        ///
        /// Expressed in bytes rather than frames so the buffer stays bounded whatever
        /// the channel count and bit depth: `WAVReader` puts no upper bound on the
        /// channel count a `fmt ` chunk may declare.
        public static let targetBytes = 2 * 1024 * 1024

        /// Floor for pathological formats (very high channel counts), so a block
        /// always holds a usable number of frames.
        public static let minFrames = 1024
    }

    public enum URLs {
        public static let versionFeed = "https://romaindalverny.com/atelier/desgrana/version.json"
        public static let github      = "https://github.com/rdalverny/desgrana"
    }
}
