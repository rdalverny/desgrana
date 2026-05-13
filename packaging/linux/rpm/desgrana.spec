Name:           desgrana
Version:        %{_pkg_version}
Release:        1%{?dist}
Summary:        Extract channels from Behringer Wing multitrack WAV recordings
License:        MIT
URL:            https://github.com/rdalverny/desgrana

# Binaries are pre-built; no compilation here.
%global debug_package %{nil}

Requires:       qt6-qtbase
Requires:       libcurl

%description
Desgrana extracts individual mono or stereo tracks from interleaved
multichannel WAV files recorded by a Behringer Wing (or X-Live) console.

It reads session metadata from SE_LOG.BIN, channel names and stereo pairs
from a Wing snapshot (.snap), skips silent channels automatically, and
exports markers as cue chunks in every output WAV, plus CSV and MIDI files.

Includes a command-line tool (desgrana) and a graphical interface
(desgrana-gui).

%install
# Binaries
install -Dm755 %{_sourcedir}/desgrana     %{buildroot}%{_bindir}/desgrana
install -Dm755 %{_sourcedir}/desgrana-gui %{buildroot}%{_bindir}/desgrana-gui

# Bundled Swift private libs (accessed via RPATH baked into the binary)
for lib in %{_sourcedir}/swift-libs/*.so; do
    install -Dm755 "$lib" %{buildroot}/usr/lib/desgrana/
done

# Desktop integration
install -Dm644 %{_sourcedir}/desgrana-gui.desktop \
    %{buildroot}%{_datadir}/applications/desgrana-gui.desktop

for size in 16 32 48 64 128 256 512; do
    install -Dm644 \
        %{_sourcedir}/icons/hicolor/${size}x${size}/apps/desgrana.png \
        %{buildroot}%{_datadir}/icons/hicolor/${size}x${size}/apps/desgrana.png
done

%files
%{_bindir}/desgrana
%{_bindir}/desgrana-gui
/usr/lib/desgrana/*.so
%{_datadir}/applications/desgrana-gui.desktop
%{_datadir}/icons/hicolor/*/apps/desgrana.png
