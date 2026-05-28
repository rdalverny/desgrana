cmake_minimum_required(VERSION 3.20)
project(DesgranaQt CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Widgets Network)

file(READ "${CMAKE_SOURCE_DIR}/../VERSION" DESGRANA_VERSION)
string(STRIP "${DESGRANA_VERSION}" DESGRANA_VERSION)
add_compile_definitions(DESGRANA_VERSION="${DESGRANA_VERSION}")

# SPM puts object files in <target>.build/ subdirectories, not .a archives.
# Collect .o files from the four relevant targets only (excludes CLI main and macOS targets).
set(SWIFT_BUILD_DIR "${CMAKE_SOURCE_DIR}/../desgrana/.build/release"
    CACHE PATH "SPM release build output directory")

set(_SWIFT_TARGETS CWav DesgranaCore DesgranaCoreWav DesgranaBridgeC)
set(SWIFT_OBJECTS "")
foreach(_tgt ${_SWIFT_TARGETS})
    file(GLOB_RECURSE _objs "${SWIFT_BUILD_DIR}/${_tgt}.build/*.o")
    list(APPEND SWIFT_OBJECTS ${_objs})
endforeach()

if(NOT SWIFT_OBJECTS)
    message(FATAL_ERROR
        "No Swift object files found under ${SWIFT_BUILD_DIR}.\n"
        "Run: cd desgrana && swift build -c release --product desgrana\n"
        "     cd desgrana && swift build -c release --target DesgranaBridgeC")
endif()

# Swift runtime location at build time (inside the Docker builder)
set(SWIFT_RUNTIME_DIR "/usr/lib/swift/linux"
    CACHE PATH "Swift runtime library directory (build-time)")
# RPATH embedded in the installed binary (where the .deb puts the Swift dylibs)
set(DESGRANA_INSTALL_RPATH "/usr/lib/desgrana"
    CACHE PATH "RPATH embedded in the installed desgrana-gui binary")

qt_add_executable(desgrana-linux
    main.cpp
    DesgranaWindow.cpp
    SplitWorker.cpp
)

target_include_directories(desgrana-linux PRIVATE include)

target_link_libraries(desgrana-linux PRIVATE
    Qt6::Widgets
    Qt6::Network
    ${SWIFT_OBJECTS}
    "-L${SWIFT_RUNTIME_DIR}"
    swiftCore
    swift_Concurrency
    swiftDispatch
    Foundation
    FoundationEssentials
    FoundationInternationalization
    FoundationNetworking
    dispatch
    BlocksRuntime
    pthread
    dl
    m
)

target_link_options(desgrana-linux PRIVATE
    -Wl,--as-needed
    -Wl,--build-id
)

set_target_properties(desgrana-linux PROPERTIES
    INSTALL_RPATH "${DESGRANA_INSTALL_RPATH}"
    BUILD_RPATH   "${SWIFT_RUNTIME_DIR}"
)
