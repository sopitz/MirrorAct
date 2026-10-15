# SPDX-License-Identifier: GPL-3.0-or-later
# mirroract-airplay: the AirPlay receiver as a separate program (see README.md).
#
#   cmake -S AirPlayHelper -B build/airplay-helper -DCMAKE_BUILD_TYPE=Release
#   cmake --build build/airplay-helper
#
# macOS: links the same prebuilt libraries as the Mac app (Vendor/uxplay-build from
# scripts/bootstrap-uxplay.sh, OpenSSL and libplist statically from Homebrew; Bonjour via dns_sd).
# Windows (MinGW/MSYS2) and Linux: builds UxPlay's libraries from Vendor/UxPlay alongside, with its
# own mDNS responder lib/mdnsd; UxPlay's main CMake (GStreamer) is not used.

cmake_minimum_required(VERSION 3.16)

if(APPLE AND NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0" CACHE STRING "Minimum macOS version (same as the app)")
endif()

project(mirroract-airplay C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

get_filename_component(MIRRORACT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
set(UXPLAY_SRC "${MIRRORACT_ROOT}/Vendor/UxPlay")
set(BRIDGE_DIR "${MIRRORACT_ROOT}/MirrorAct/AirPlay")

if(NOT EXISTS "${UXPLAY_SRC}/lib/raop.h")
  message(FATAL_ERROR "UxPlay sources missing in ${UXPLAY_SRC}: run scripts/bootstrap-uxplay.sh (macOS) "
                      "or fetch the pinned commit from that script (see .github/workflows/airplay-helper.yml)")
endif()

add_executable(mirroract-airplay main.c "${BRIDGE_DIR}/airplay_bridge.c")
target_include_directories(mirroract-airplay PRIVATE "${BRIDGE_DIR}" "${UXPLAY_SRC}/lib")
target_compile_options(mirroract-airplay PRIVATE "$<$<COMPILE_LANGUAGE:C>:-Wall;-Wextra;-Wno-unused-parameter>")
if(WIN32)
  # Manifest with activeCodePage UTF-8 (see mirroract-airplay.rc): argv, the STARTED JSON, the
  # mDNS name and UxPlay's fopen of the key file then work with UTF-8 as on the Mac.
  # binutils uses it to replace MinGW's default manifest (default-manifest.o).
  enable_language(RC)
  target_sources(mirroract-airplay PRIVATE mirroract-airplay.rc)
  set_source_files_properties(mirroract-airplay.rc PROPERTIES
      OBJECT_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/mirroract-airplay.manifest")
endif()

if(APPLE)
  if(DEFINED ENV{HOMEBREW_PREFIX})
    set(BREW_PREFIX "$ENV{HOMEBREW_PREFIX}")
  else()
    execute_process(COMMAND brew --prefix OUTPUT_VARIABLE BREW_PREFIX OUTPUT_STRIP_TRAILING_WHITESPACE
                    RESULT_VARIABLE brew_result ERROR_QUIET)
    if(NOT brew_result EQUAL 0)
      set(BREW_PREFIX "/opt/homebrew")
    endif()
  endif()
  set(UXPLAY_BUILD "${MIRRORACT_ROOT}/Vendor/uxplay-build")
  set(UXPLAY_LIBS
      "${UXPLAY_BUILD}/lib/libairplay.a"
      "${UXPLAY_BUILD}/lib/playfair/libplayfair.a"
      "${UXPLAY_BUILD}/lib/llhttp/libllhttp.a"
      "${UXPLAY_BUILD}/lib/dns_sd/libdnssd.a")
  foreach(lib ${UXPLAY_LIBS} "${BREW_PREFIX}/opt/openssl@3/lib/libcrypto.a" "${BREW_PREFIX}/opt/libplist/lib/libplist-2.0.a")
    if(NOT EXISTS "${lib}")
      message(FATAL_ERROR "${lib} missing: run scripts/bootstrap-uxplay.sh and brew install openssl@3 libplist")
    endif()
  endforeach()
  # same definitions as the app (project.yml): with UXPLAY_HAVE_APPLE_P2P, dnssd_t has one more field
  target_compile_definitions(mirroract-airplay PRIVATE
      EXTERNAL_DNS_SD=1 UXPLAY_HAVE_APPLE_P2P=1 NOHOLD=1 PLIST_210=1 PLIST_230=1 SYS_ENDIAN_H=1)
  target_include_directories(mirroract-airplay PRIVATE
      "${BREW_PREFIX}/opt/openssl@3/include" "${BREW_PREFIX}/opt/libplist/include")
  target_link_libraries(mirroract-airplay PRIVATE
      ${UXPLAY_LIBS}
      "${BREW_PREFIX}/opt/openssl@3/lib/libcrypto.a"
      "${BREW_PREFIX}/opt/libplist/lib/libplist-2.0.a"
      pthread)
else()
  set(NO_MARCH_NATIVE ON)
  if(WIN32)
    # UxPlay checks WIN32 in some places, _WIN32 in others; static libraries so only system DLLs remain.
    # LIBPLIST_STATIC: otherwise plist.h expects the functions as DLL imports (__imp_plist_*)
    add_compile_definitions(WIN32 LIBPLIST_STATIC)
    set(OPENSSL_USE_STATIC_LIBS ON)
    set(CMAKE_FIND_LIBRARY_SUFFIXES .a)
    # the system import libraries must come after libcrypto.a and libairplay.a (single linker
    # pass): CMAKE_C_STANDARD_LIBRARIES goes at the end of every link line
    set(CMAKE_C_STANDARD_LIBRARIES "${CMAKE_C_STANDARD_LIBRARIES} -lws2_32 -liphlpapi -lbcrypt -lcrypt32 -ladvapi32")
  endif()
  add_subdirectory("${UXPLAY_SRC}/lib/llhttp" uxplay/llhttp)
  add_subdirectory("${UXPLAY_SRC}/lib/playfair" uxplay/playfair)
  add_subdirectory("${UXPLAY_SRC}/lib/mdnsd" uxplay/mdnsd)
  add_subdirectory("${UXPLAY_SRC}/lib" uxplay/lib)
  # lib/mdnsd needs utils_hwaddr_* from libairplay: a cycle that CMake resolves for static libraries
  # by repeating them on the link line
  target_link_libraries(dnssd PUBLIC airplay)
  target_link_libraries(mirroract-airplay PRIVATE airplay dnssd playfair llhttp)
  if(WIN32)
    target_link_libraries(mirroract-airplay PRIVATE ws2_32 iphlpapi bcrypt crypt32 advapi32)
    target_link_options(mirroract-airplay PRIVATE -static)
  else()
    # playfair uses sin() (libm)
    target_link_libraries(mirroract-airplay PRIVATE pthread m)
  endif()
endif()

install(TARGETS mirroract-airplay RUNTIME DESTINATION bin)
