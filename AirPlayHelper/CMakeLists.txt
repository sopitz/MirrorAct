# SPDX-License-Identifier: GPL-3.0-or-later
# mirroract-airplay: AirPlay-Empfänger als eigenes Programm (siehe README.md).
#
#   cmake -S AirPlayHelper -B build/airplay-helper -DCMAKE_BUILD_TYPE=Release
#   cmake --build build/airplay-helper
#
# macOS: linkt dieselben fertigen Bibliotheken wie die Mac-App (Vendor/uxplay-build nach
# scripts/bootstrap-uxplay.sh, OpenSSL und libplist statisch aus Homebrew; Bonjour über dns_sd).
# Windows (MinGW/MSYS2) und Linux: baut UxPlays Bibliotheken aus Vendor/UxPlay mit, mit dessen
# eigenem mDNS-Responder lib/mdnsd; UxPlays Haupt-CMake (GStreamer) wird nicht benutzt.

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
target_compile_options(mirroract-airplay PRIVATE -Wall -Wextra -Wno-unused-parameter)

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
  # dieselben Definitionen wie die App (project.yml): dnssd_t hat mit UXPLAY_HAVE_APPLE_P2P ein Feld mehr
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
    # UxPlay prüft teils WIN32, teils _WIN32; statische Bibliotheken, damit nur System-DLLs bleiben.
    # LIBPLIST_STATIC: sonst erwartet plist.h die Funktionen als DLL-Import (__imp_plist_*)
    add_compile_definitions(WIN32 LIBPLIST_STATIC)
    set(OPENSSL_USE_STATIC_LIBS ON)
    set(CMAKE_FIND_LIBRARY_SUFFIXES .a)
    # die System-Importbibliotheken müssen hinter libcrypto.a und libairplay.a stehen (ein Durchlauf
    # des Linkers): CMAKE_C_STANDARD_LIBRARIES kommt ans Ende jeder Linkzeile
    set(CMAKE_C_STANDARD_LIBRARIES "${CMAKE_C_STANDARD_LIBRARIES} -lws2_32 -liphlpapi -lbcrypt -lcrypt32 -ladvapi32")
  endif()
  add_subdirectory("${UXPLAY_SRC}/lib/llhttp" uxplay/llhttp)
  add_subdirectory("${UXPLAY_SRC}/lib/playfair" uxplay/playfair)
  add_subdirectory("${UXPLAY_SRC}/lib/mdnsd" uxplay/mdnsd)
  add_subdirectory("${UXPLAY_SRC}/lib" uxplay/lib)
  # lib/mdnsd braucht utils_hwaddr_* aus libairplay: Kreis, den CMake für statische Bibliotheken
  # durch Wiederholen auf der Linkzeile auflöst
  target_link_libraries(dnssd PUBLIC airplay)
  target_link_libraries(mirroract-airplay PRIVATE airplay dnssd playfair llhttp)
  if(WIN32)
    target_link_libraries(mirroract-airplay PRIVATE ws2_32 iphlpapi bcrypt crypt32 advapi32)
    target_link_options(mirroract-airplay PRIVATE -static)
  else()
    # playfair rechnet mit sin() (libm)
    target_link_libraries(mirroract-airplay PRIVATE pthread m)
  endif()
endif()

install(TARGETS mirroract-airplay RUNTIME DESTINATION bin)
