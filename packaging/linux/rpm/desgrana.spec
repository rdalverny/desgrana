Name:           desgrana
Version:        %{_pkg_version}
Release:        1%{?dist}
Summary:        Extract channels from Behringer Wing and X32 multitrack WAV recordings
License:        MIT
URL:            https://github.com/rdalverny/desgrana

%global debug_package %{nil}

Requires:       qt6-qtbase
Requires:       libcurl

%description
Desgrana extracts individual mono or stereo tracks from interleaved
multichannel WAV files recorded by a Behringer Wing or X32 console.

It reads session metadata from SE_LOG.BIN, channel names and stereo pairs
from a console snapshot (.snap or .scn), skips silent channels automatically, and
exports markers as cue chunks in every output WAV, plus CSV and MIDI files.

Includes a command-line tool (desgrana) and a graphical interface
(desgrana-gui).

%install
install -Dm755 %{_sourcedir}/desgrana     %{buildroot}%{_bindir}/desgrana
install -Dm755 %{_sourcedir}/desgrana-gui %{buildroot}%{_bindir}/desgrana-gui

install -Dm644 %{_sourcedir}/man/desgrana.1     %{buildroot}%{_mandir}/man1/desgrana.1
install -Dm644 %{_sourcedir}/man/desgrana-gui.1 %{buildroot}%{_mandir}/man1/desgrana-gui.1

install -d %{buildroot}/usr/lib/desgrana
cp %{_sourcedir}/swift-libs/*.so %{buildroot}/usr/lib/desgrana/

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
%{_mandir}/man1/desgrana.1*
%{_mandir}/man1/desgrana-gui.1*
/usr/lib/desgrana/*.so
%{_datadir}/applications/desgrana-gui.desktop
%{_datadir}/icons/hicolor/*/apps/desgrana.png

%changelog
* Mon Oct 12 2026 Romain d'Alverny <rwx@romaindalverny.com> - 1.13.0-1
- Release 1.13.0.

* Wed May 13 2026 Romain d'Alverny <rwx@romaindalverny.com> - 1.8.0-1
- Initial RPM package.
