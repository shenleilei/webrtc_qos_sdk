cmake_minimum_required(VERSION 3.16)

project(webrtc_qos_sdk
  VERSION 0.1.0
  LANGUAGES CXX)

include(CMakePackageConfigHelpers)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(WEBRTC_QOS_PUBLIC_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/include")

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
  src/h264_annexb.cc)

webrtc_qos_object_library(webrtc_qos_rtp_obj
  src/rtp_packet.cc)

webrtc_qos_object_library(webrtc_qos_rtcp_obj
  src/rtcp_packets.cc)

webrtc_qos_object_library(webrtc_qos_feedback_obj
  src/sender_qos_controller.cc
  src/transport_feedback.cc)

webrtc_qos_object_library(webrtc_qos_transport_obj
  src/production_transport_adapter.cc
  src/transport_port.cc)

webrtc_qos_object_library(webrtc_qos_nack_obj
  src/receiver_qos_observer.cc
  src/retransmission_cache.cc)

webrtc_qos_object_library(webrtc_qos_pacer_obj
  src/sender_pacer.cc)

webrtc_qos_object_library(webrtc_qos_video_obj
  src/video_jitter_player.cc
  src/video_receiver.cc
  src/video_sender.cc)

webrtc_qos_static_library(webrtc_qos_core webrtc_qos_core_obj)
webrtc_qos_static_library(webrtc_qos_rtp webrtc_qos_rtp_obj)
webrtc_qos_static_library(webrtc_qos_rtcp webrtc_qos_rtcp_obj)
webrtc_qos_static_library(webrtc_qos_feedback webrtc_qos_feedback_obj)
webrtc_qos_static_library(webrtc_qos_transport webrtc_qos_transport_obj)
webrtc_qos_static_library(webrtc_qos_nack webrtc_qos_nack_obj)
webrtc_qos_static_library(webrtc_qos_pacer webrtc_qos_pacer_obj)
webrtc_qos_static_library(webrtc_qos_video webrtc_qos_video_obj)

target_link_libraries(webrtc_qos_video INTERFACE webrtc_qos_core)

add_library(webrtc_qos STATIC
  $<TARGET_OBJECTS:webrtc_qos_core_obj>
  $<TARGET_OBJECTS:webrtc_qos_rtp_obj>
  $<TARGET_OBJECTS:webrtc_qos_rtcp_obj>
  $<TARGET_OBJECTS:webrtc_qos_feedback_obj>
  $<TARGET_OBJECTS:webrtc_qos_transport_obj>
  $<TARGET_OBJECTS:webrtc_qos_nack_obj>
  $<TARGET_OBJECTS:webrtc_qos_pacer_obj>
  $<TARGET_OBJECTS:webrtc_qos_video_obj>)
target_include_directories(webrtc_qos
  PUBLIC
    $<BUILD_INTERFACE:${WEBRTC_QOS_PUBLIC_INCLUDE_DIR}>
    $<INSTALL_INTERFACE:include>)

add_executable(qos_loopback_demo demo/loopback/main.cc)
target_link_libraries(qos_loopback_demo PRIVATE webrtc_qos)

add_executable(capture_push_demo demo/capture_push/main.cc)
target_link_libraries(capture_push_demo PRIVATE webrtc_qos)

add_executable(receive_play_demo demo/receive_play/main.cc)
target_link_libraries(receive_play_demo PRIVATE webrtc_qos)

add_executable(transport_port_demo demo/transport_port/main.cc)
target_link_libraries(transport_port_demo PRIVATE webrtc_qos)

add_executable(production_transport_demo demo/production_transport/main.cc)
target_link_libraries(production_transport_demo PRIVATE webrtc_qos)

add_executable(dynamic_qos_demo demo/dynamic_qos/main.cc)
target_link_libraries(dynamic_qos_demo PRIVATE webrtc_qos)

add_executable(webrtc_qos_selftest tests/selftest.cc)
target_link_libraries(webrtc_qos_selftest PRIVATE webrtc_qos)

install(TARGETS
  webrtc_qos
  webrtc_qos_core
  webrtc_qos_rtp
  webrtc_qos_rtcp
  webrtc_qos_feedback
  webrtc_qos_transport
  webrtc_qos_nack
  webrtc_qos_pacer
  webrtc_qos_video
  EXPORT WebRtcQosSdkTargets
  ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)
install(TARGETS
  qos_loopback_demo
  capture_push_demo
  receive_play_demo
  transport_port_demo
  production_transport_demo
  dynamic_qos_demo
  RUNTIME DESTINATION demo)

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
