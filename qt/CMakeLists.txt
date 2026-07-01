cmake_minimum_required(VERSION 3.20)
project(DesgranaQt CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Widgets Network)

file(READ "${CMAKE_SOURCE_DIR}/../VERSION" DESGRANA_VERSION)
string(STRIP "${DESGRANA_VERSION}" DESGRANA_VERSION)
add_compile_definitions(DESGRANA_VERSION="${DESGRANA_VERSION}")

# The Swift side is consumed as a single shared library (SwiftPM .dynamic
# product, built from Sources/BridgeC). It exposes the C ABI (@_cdecl) and pulls
# the Swift core/runtime transitively, so the GUI link no longer globs object
# files nor enumerates Swift runtime libraries by hand.
# find_library resolves libDesgranaBridge.so on Linux and DesgranaBridge.lib
# (the DLL import library) on Windows.
set(SWIFT_BUILD_DIR "${CMAKE_SOURCE_DIR}/../desgrana/.build/release"
    CACHE PATH "SPM release build output directory")

find_library(DESGRANA_BRIDGE
    NAMES DesgranaBridge
    PATHS "${SWIFT_BUILD_DIR}"
    NO_DEFAULT_PATH)
if(NOT DESGRANA_BRIDGE)
    message(FATAL_ERROR
        "DesgranaBridge import library not found under ${SWIFT_BUILD_DIR}.\n"
        "Run: cd desgrana && swift build -c release --product DesgranaBridge")
endif()

# Linux only: where the Swift runtime lives at build time, and the rpath baked
# into the installed binary (the .deb drops the Swift dylibs there).
set(SWIFT_RUNTIME_DIR "/usr/lib/swift/linux"
    CACHE PATH "Swift runtime library directory (build-time)")
set(DESGRANA_INSTALL_RPATH "/usr/lib/desgrana"
    CACHE PATH "RPATH embedded in the installed desgrana-gui binary")

# Same target name on every OS — it already matches the installed binary
# (desgrana-gui / desgrana-gui.exe), so packaging no longer renames it.
set(GUI_TARGET desgrana-gui)

# WIN32: build as a GUI-subsystem app (no console window). Ignored on other OSes.
qt_add_executable(${GUI_TARGET} WIN32
    main.cpp
    DesgranaWindow.cpp
    SplitWorker.cpp
)

target_include_directories(${GUI_TARGET} PRIVATE include)

target_link_libraries(${GUI_TARGET} PRIVATE
    Qt6::Widgets
    Qt6::Network
    ${DESGRANA_BRIDGE}
)

if(WIN32)
    # Embed the app icon into the exe (also used by the shortcut and uninstaller).
    # configure_file bakes an absolute path so the resource compiler always finds it.
    set(DESGRANA_ICO "${CMAKE_SOURCE_DIR}/../packaging/win/desgrana.ico")
    configure_file(desgrana.rc.in "${CMAKE_CURRENT_BINARY_DIR}/desgrana.rc" @ONLY)
    target_sources(${GUI_TARGET} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/desgrana.rc")

    # Ship the bridge DLL next to the exe. The Swift runtime DLLs it needs are
    # bundled separately at packaging time (-static-stdlib is unavailable here).
    add_custom_command(TARGET ${GUI_TARGET} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${SWIFT_BUILD_DIR}/DesgranaBridge.dll"
            "$<TARGET_FILE_DIR:${GUI_TARGET}>")
else()
    # The bridge .so pulls the Swift runtime; -L lets the linker resolve its
    # NEEDED entries at link time. Runtime rpath lives on the .so itself ($ORIGIN).
    target_link_libraries(${GUI_TARGET} PRIVATE "-L${SWIFT_RUNTIME_DIR}")
    target_link_options(${GUI_TARGET} PRIVATE
        -Wl,--as-needed
        -Wl,--build-id
    )
    set_target_properties(${GUI_TARGET} PROPERTIES
        INSTALL_RPATH "${DESGRANA_INSTALL_RPATH}"
        BUILD_RPATH   "${SWIFT_RUNTIME_DIR}"
    )
endif()
