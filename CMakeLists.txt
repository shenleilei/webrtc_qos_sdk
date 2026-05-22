cmake_minimum_required(VERSION 3.16)

project(webrtc_qos_sdk
  VERSION 0.1.0
  LANGUAGES CXX)

include(CMakePackageConfigHelpers)
find_package(Threads REQUIRED)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(WEBRTC_QOS_PUBLIC_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/include")
option(WEBRTC_QOS_ENABLE_FFMPEG_ENCODER
  "Build optional FFmpeg/libavcodec H264 encoder/decoder adapters" OFF)
option(WEBRTC_QOS_INSTALL_FFMPEG_ENCODER
  "Install optional FFmpeg/libavcodec H264 encoder/decoder adapters" OFF)
option(WEBRTC_QOS_ENABLE_WEBRTC_FACADE
  "Build WebRTC-backed facade implementation; disabling is maintenance-only and not a supported Phase-2 delivery mode" ON)
set(WEBRTC_QOS_WEBRTC_MODULE_PREFIX "${CMAKE_CURRENT_SOURCE_DIR}/dist/linux-x86_64" CACHE PATH
  "Prefix containing packaged WebRTC QoS module headers/libs")

function(webrtc_qos_object_library target)
  add_library(${target} OBJECT ${ARGN})
  target_include_directories(${target}
    PUBLIC
      $<BUILD_INTERFACE:${WEBRTC_QOS_PUBLIC_INCLUDE_DIR}>
      $<INSTALL_INTERFACE:include>
    PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/src)
  target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic)
  set_target_properties(${target} PROPERTIES POSITION_INDEPENDENT_CODE ON)
endfunction()

function(webrtc_qos_static_library target object_target)
  add_library(${target} STATIC $<TARGET_OBJECTS:${object_target}>)
  target_include_directories(${target}
    PUBLIC
      $<BUILD_INTERFACE:${WEBRTC_QOS_PUBLIC_INCLUDE_DIR}>
      $<INSTALL_INTERFACE:include>)
endfunction()

webrtc_qos_object_library(webrtc_qos_core_obj
  src/sdk_version.cc)

webrtc_qos_object_library(webrtc_qos_transport_obj
  src/production_transport_adapter.cc
  src/transport_port.cc)

webrtc_qos_object_library(webrtc_qos_transport_packet_history_obj
  src/transport_packet_history.cc)

webrtc_qos_static_library(webrtc_qos_core webrtc_qos_core_obj)
webrtc_qos_static_library(webrtc_qos_transport webrtc_qos_transport_obj)
webrtc_qos_static_library(webrtc_qos_transport_packet_history
  webrtc_qos_transport_packet_history_obj)

set(WEBRTC_QOS_WEBRTC_FACADE_INSTALL_TARGETS)
set(WEBRTC_QOS_FFMPEG_INSTALL_TARGETS)
set(WEBRTC_QOS_OPTIONAL_DEMO_TARGETS)
set(WEBRTC_QOS_WEBRTC_MODULE_ARCHIVES)
set(WEBRTC_QOS_WEBRTC_MODULE_HEADERS)
set(WEBRTC_QOS_ROLE_BUNDLE_ARCHIVES)
if(WEBRTC_QOS_ENABLE_WEBRTC_FACADE)
  if(NOT WEBRTC_QOS_WEBRTC_MODULE_PREFIX)
    message(FATAL_ERROR
      "WEBRTC_QOS_ENABLE_WEBRTC_FACADE requires WEBRTC_QOS_WEBRTC_MODULE_PREFIX")
  endif()
  set(WEBRTC_QOS_WEBRTC_MODULE_INCLUDE_DIR
    "${WEBRTC_QOS_WEBRTC_MODULE_PREFIX}/include")
  set(WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR
    "${WEBRTC_QOS_WEBRTC_MODULE_PREFIX}/lib")
  foreach(_archive IN ITEMS
      libwebrtc_qos_webrtc_googcc.a
      libwebrtc_qos_webrtc_rtp_rtcp.a
      libwebrtc_qos_webrtc_pacing.a
      libwebrtc_qos_webrtc_nack_requester.a
      libwebrtc_qos_webrtc_video_jitter.a)
    if(NOT EXISTS "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/${_archive}")
      message(FATAL_ERROR
        "missing required WebRTC module archive: ${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/${_archive}")
    endif()
    list(APPEND WEBRTC_QOS_WEBRTC_MODULE_ARCHIVES
      "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/${_archive}")
  endforeach()
  foreach(_header IN ITEMS
      googcc_adapter.h
      h264_rtp_adapter.h
      nack_requester_adapter.h
      rtcp_adapter.h
      pacing_adapter.h
      rtp_packet_adapter.h
      video_jitter_adapter.h)
    if(NOT EXISTS "${WEBRTC_QOS_WEBRTC_MODULE_INCLUDE_DIR}/webrtc_qos/${_header}")
      message(FATAL_ERROR
        "missing required WebRTC module header: ${WEBRTC_QOS_WEBRTC_MODULE_INCLUDE_DIR}/webrtc_qos/${_header}")
    endif()
    list(APPEND WEBRTC_QOS_WEBRTC_MODULE_HEADERS
      "${WEBRTC_QOS_WEBRTC_MODULE_INCLUDE_DIR}/webrtc_qos/${_header}")
  endforeach()

  add_library(webrtc_qos_facade_video STATIC
    src/runtime_alert_writer.cc
    src/runtime_logger.cc
    src/runtime_metrics_writer.cc
    src/server_qos_router_webrtc.cc
    src/video_play_client_webrtc.cc
    src/video_push_client_webrtc.cc)
  target_include_directories(webrtc_qos_facade_video
    PUBLIC
      $<BUILD_INTERFACE:${WEBRTC_QOS_PUBLIC_INCLUDE_DIR}>
      $<INSTALL_INTERFACE:include>
    PRIVATE
      "${WEBRTC_QOS_WEBRTC_MODULE_INCLUDE_DIR}"
      ${CMAKE_CURRENT_SOURCE_DIR}/src)
  target_compile_options(webrtc_qos_facade_video
    PRIVATE -Wall -Wextra -Wpedantic)
  list(APPEND WEBRTC_QOS_WEBRTC_FACADE_INSTALL_TARGETS
    webrtc_qos_facade_video)

  add_executable(webrtc_qos_webrtc_first_loopback_demo
    demo/webrtc_first_loopback/main.cc)
  target_include_directories(webrtc_qos_webrtc_first_loopback_demo
    PRIVATE
      "${WEBRTC_QOS_PUBLIC_INCLUDE_DIR}")
  target_compile_options(webrtc_qos_webrtc_first_loopback_demo
    PRIVATE -Wall -Wextra -Wpedantic)
  target_link_libraries(webrtc_qos_webrtc_first_loopback_demo
    PRIVATE
      webrtc_qos_facade_video
      webrtc_qos_transport
      webrtc_qos_transport_packet_history
      "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/libwebrtc_qos_webrtc_googcc.a"
      "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/libwebrtc_qos_webrtc_pacing.a"
      "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/libwebrtc_qos_webrtc_rtp_rtcp.a"
      "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/libwebrtc_qos_webrtc_video_jitter.a"
      "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/libwebrtc_qos_webrtc_nack_requester.a"
      Threads::Threads
      dl
      rt
      atomic)
  list(APPEND WEBRTC_QOS_OPTIONAL_DEMO_TARGETS
    webrtc_qos_webrtc_first_loopback_demo)

  add_executable(webrtc_qos_webrtc_first_udp_demo
    demo/webrtc_first_udp/main.cc)
  target_include_directories(webrtc_qos_webrtc_first_udp_demo
    PRIVATE
      "${WEBRTC_QOS_PUBLIC_INCLUDE_DIR}")
  target_compile_options(webrtc_qos_webrtc_first_udp_demo
    PRIVATE -Wall -Wextra -Wpedantic)
  target_link_libraries(webrtc_qos_webrtc_first_udp_demo
    PRIVATE
      webrtc_qos_facade_video
      webrtc_qos_transport
      webrtc_qos_transport_packet_history
      "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/libwebrtc_qos_webrtc_googcc.a"
      "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/libwebrtc_qos_webrtc_pacing.a"
      "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/libwebrtc_qos_webrtc_rtp_rtcp.a"
      "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/libwebrtc_qos_webrtc_video_jitter.a"
      "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/libwebrtc_qos_webrtc_nack_requester.a"
      Threads::Threads
      dl
      rt
      atomic)
  list(APPEND WEBRTC_QOS_OPTIONAL_DEMO_TARGETS
    webrtc_qos_webrtc_first_udp_demo)

  function(webrtc_qos_add_role_bundle target_name output_name)
    set(options)
    set(oneValueArgs)
    set(multiValueArgs ARCHIVES)
    cmake_parse_arguments(BUNDLE "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})
    if(NOT BUNDLE_ARCHIVES)
      message(FATAL_ERROR "webrtc_qos_add_role_bundle requires ARCHIVES")
    endif()
    set(_output "${CMAKE_CURRENT_BINARY_DIR}/${output_name}")
    add_custom_command(
      OUTPUT "${_output}"
      COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/scripts/merge_static_archives.sh"
        "${CMAKE_AR}" "${_output}" ${BUNDLE_ARCHIVES}
      DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/scripts/merge_static_archives.sh"
        ${BUNDLE_ARCHIVES}
      VERBATIM)
    add_custom_target(${target_name} ALL DEPENDS "${_output}")
    list(APPEND WEBRTC_QOS_ROLE_BUNDLE_ARCHIVES "${_output}")
    set(WEBRTC_QOS_ROLE_BUNDLE_ARCHIVES "${WEBRTC_QOS_ROLE_BUNDLE_ARCHIVES}" PARENT_SCOPE)
  endfunction()

  webrtc_qos_add_role_bundle(
    webrtc_qos_role_push_bundle
    libwebrtc_qos_role_push_bundle.a
    ARCHIVES
      $<TARGET_FILE:webrtc_qos>
      $<TARGET_FILE:webrtc_qos_facade_video>
      "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/libwebrtc_qos_webrtc_googcc.a"
      "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/libwebrtc_qos_webrtc_pacing.a"
      "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/libwebrtc_qos_webrtc_rtp_rtcp.a")

  webrtc_qos_add_role_bundle(
    webrtc_qos_role_play_bundle
    libwebrtc_qos_role_play_bundle.a
    ARCHIVES
      $<TARGET_FILE:webrtc_qos>
      $<TARGET_FILE:webrtc_qos_facade_video>
      "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/libwebrtc_qos_webrtc_rtp_rtcp.a"
      "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/libwebrtc_qos_webrtc_video_jitter.a"
      "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/libwebrtc_qos_webrtc_nack_requester.a")

  webrtc_qos_add_role_bundle(
    webrtc_qos_role_server_bundle
    libwebrtc_qos_role_server_bundle.a
    ARCHIVES
      $<TARGET_FILE:webrtc_qos>
      $<TARGET_FILE:webrtc_qos_facade_video>
      "${WEBRTC_QOS_WEBRTC_MODULE_LIB_DIR}/libwebrtc_qos_webrtc_rtp_rtcp.a")
endif()
if(WEBRTC_QOS_ENABLE_FFMPEG_ENCODER)
  find_path(FFMPEG_INCLUDE_DIR
    NAMES libavcodec/avcodec.h
    PATHS /usr/include/ffmpeg /usr/local/include/ffmpeg /usr/include
    NO_DEFAULT_PATH)
  find_path(FFMPEG_INCLUDE_DIR
    NAMES libavcodec/avcodec.h)
  find_library(AVCODEC_LIBRARY avcodec)
  find_library(AVUTIL_LIBRARY avutil)
  find_library(SWSCALE_LIBRARY swscale)
  if(FFMPEG_INCLUDE_DIR AND AVCODEC_LIBRARY AND AVUTIL_LIBRARY AND SWSCALE_LIBRARY)
    add_library(webrtc_qos_ffmpeg_encoder STATIC
      src/ffmpeg_h264_encoder.cc)
    target_include_directories(webrtc_qos_ffmpeg_encoder
      PUBLIC
        $<BUILD_INTERFACE:${WEBRTC_QOS_PUBLIC_INCLUDE_DIR}>
        $<INSTALL_INTERFACE:include>
      PRIVATE
        ${FFMPEG_INCLUDE_DIR}
        ${CMAKE_CURRENT_SOURCE_DIR}/src)
    target_compile_options(webrtc_qos_ffmpeg_encoder
      PRIVATE -Wall -Wextra -Wpedantic)
    target_link_libraries(webrtc_qos_ffmpeg_encoder
      INTERFACE ${AVCODEC_LIBRARY} ${AVUTIL_LIBRARY})
    add_library(webrtc_qos_ffmpeg_decoder STATIC
      src/ffmpeg_h264_decoder.cc)
    target_include_directories(webrtc_qos_ffmpeg_decoder
      PUBLIC
        $<BUILD_INTERFACE:${WEBRTC_QOS_PUBLIC_INCLUDE_DIR}>
        $<INSTALL_INTERFACE:include>
      PRIVATE
        ${FFMPEG_INCLUDE_DIR}
        ${CMAKE_CURRENT_SOURCE_DIR}/src)
    target_compile_options(webrtc_qos_ffmpeg_decoder
      PRIVATE -Wall -Wextra -Wpedantic)
    target_link_libraries(webrtc_qos_ffmpeg_decoder
      INTERFACE ${AVCODEC_LIBRARY} ${AVUTIL_LIBRARY} ${SWSCALE_LIBRARY})
    list(APPEND WEBRTC_QOS_FFMPEG_INSTALL_TARGETS
      webrtc_qos_ffmpeg_encoder
      webrtc_qos_ffmpeg_decoder)
  else()
    message(STATUS "FFmpeg H264 encoder/decoder adapters disabled: headers/libs not found")
  endif()
endif()

add_library(webrtc_qos STATIC
  $<TARGET_OBJECTS:webrtc_qos_core_obj>
  $<TARGET_OBJECTS:webrtc_qos_transport_obj>
  $<TARGET_OBJECTS:webrtc_qos_transport_packet_history_obj>)
target_include_directories(webrtc_qos
  PUBLIC
    $<BUILD_INTERFACE:${WEBRTC_QOS_PUBLIC_INCLUDE_DIR}>
    $<INSTALL_INTERFACE:include>)

add_executable(webrtc_qos_selftest tests/selftest.cc)
target_link_libraries(webrtc_qos_selftest PRIVATE webrtc_qos)

if(WEBRTC_QOS_OPTIONAL_DEMO_TARGETS)
  add_custom_target(webrtc_qos_demos
    DEPENDS ${WEBRTC_QOS_OPTIONAL_DEMO_TARGETS})
endif()

install(TARGETS
  webrtc_qos
  webrtc_qos_core
  webrtc_qos_transport
  webrtc_qos_transport_packet_history
  EXPORT WebRtcQosSdkTargets
  ARCHIVE DESTINATION lib)
if(WEBRTC_QOS_WEBRTC_FACADE_INSTALL_TARGETS)
  install(TARGETS
    ${WEBRTC_QOS_WEBRTC_FACADE_INSTALL_TARGETS}
    EXPORT WebRtcQosSdkTargets
    ARCHIVE DESTINATION lib)
  install(FILES
    ${WEBRTC_QOS_WEBRTC_MODULE_ARCHIVES}
    DESTINATION lib)
  install(FILES
    ${WEBRTC_QOS_WEBRTC_MODULE_HEADERS}
    DESTINATION include/webrtc_qos)
  if(WEBRTC_QOS_ROLE_BUNDLE_ARCHIVES)
    install(FILES
      ${WEBRTC_QOS_ROLE_BUNDLE_ARCHIVES}
      DESTINATION lib)
  endif()
endif()
if(WEBRTC_QOS_INSTALL_FFMPEG_ENCODER AND WEBRTC_QOS_FFMPEG_INSTALL_TARGETS)
  install(TARGETS
    ${WEBRTC_QOS_FFMPEG_INSTALL_TARGETS}
    EXPORT WebRtcQosSdkTargets
    ARCHIVE DESTINATION lib)
endif()
if(WEBRTC_QOS_INSTALL_FFMPEG_ENCODER AND WEBRTC_QOS_ENABLE_FFMPEG_ENCODER)
  install(FILES
    include/webrtc_qos/ffmpeg_h264_decoder.h
    include/webrtc_qos/ffmpeg_h264_encoder.h
    DESTINATION include/webrtc_qos)
endif()
set(WEBRTC_QOS_PUBLIC_HEADERS
  include/webrtc_qos/control_messages.h
  include/webrtc_qos/production_transport_adapter.h
  include/webrtc_qos/qos_metrics.h
  include/webrtc_qos/rate_cap.h
  include/webrtc_qos/runtime_alerts.h
  include/webrtc_qos/runtime_logging.h
  include/webrtc_qos/runtime_metrics.h
  include/webrtc_qos/server_qos_router.h
  include/webrtc_qos/session_config.h
  include/webrtc_qos/status.h
  include/webrtc_qos/transport_io.h
  include/webrtc_qos/transport_packet_history.h
  include/webrtc_qos/transport_port.h
  include/webrtc_qos/types.h
  include/webrtc_qos/video_play_client.h
  include/webrtc_qos/video_push_client.h)
install(FILES ${WEBRTC_QOS_PUBLIC_HEADERS}
  DESTINATION include/webrtc_qos)
install(EXPORT WebRtcQosSdkTargets
  FILE WebRtcQosSdkTargets.cmake
  NAMESPACE WebRtcQosSdk::
  DESTINATION lib/cmake/WebRtcQosSdk)

write_basic_package_version_file(
  "${CMAKE_CURRENT_BINARY_DIR}/WebRtcQosSdkConfigVersion.cmake"
  VERSION ${PROJECT_VERSION}
  COMPATIBILITY SameMajorVersion)

configure_package_config_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/cmake/WebRtcQosSdkConfig.cmake.in"
  "${CMAKE_CURRENT_BINARY_DIR}/WebRtcQosSdkConfig.cmake"
  INSTALL_DESTINATION lib/cmake/WebRtcQosSdk)

install(FILES
  "${CMAKE_CURRENT_BINARY_DIR}/WebRtcQosSdkConfig.cmake"
  "${CMAKE_CURRENT_BINARY_DIR}/WebRtcQosSdkConfigVersion.cmake"
  DESTINATION lib/cmake/WebRtcQosSdk)
