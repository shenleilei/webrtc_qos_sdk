cmake_minimum_required(VERSION 3.16)

project(webrtc_qos_minimal_udp_app LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(WebRtcQosSdk REQUIRED CONFIG)

function(select_webrtc_qos_role out_var role_name)
  if(TARGET "WebRtcQosSdk::role_${role_name}_bundle")
    set("${out_var}" "WebRtcQosSdk::role_${role_name}_bundle" PARENT_SCOPE)
  elseif(TARGET "WebRtcQosSdk::role_${role_name}")
    set("${out_var}" "WebRtcQosSdk::role_${role_name}" PARENT_SCOPE)
  else()
    message(FATAL_ERROR "missing WebRtcQosSdk role target: ${role_name}")
  endif()
endfunction()

select_webrtc_qos_role(WEBRTC_QOS_PUSH_TARGET push)
select_webrtc_qos_role(WEBRTC_QOS_PLAY_TARGET play)
select_webrtc_qos_role(WEBRTC_QOS_SERVER_TARGET server)

add_library(minimal_udp_common INTERFACE)
target_include_directories(minimal_udp_common INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}")

add_executable(minimal_udp_sender sender/main.cc)
target_link_libraries(minimal_udp_sender PRIVATE
  minimal_udp_common
  "${WEBRTC_QOS_PUSH_TARGET}")

add_executable(minimal_udp_server server/main.cc)
target_link_libraries(minimal_udp_server PRIVATE
  minimal_udp_common
  "${WEBRTC_QOS_SERVER_TARGET}")

add_executable(minimal_udp_receiver receiver/main.cc)
target_link_libraries(minimal_udp_receiver PRIVATE
  minimal_udp_common
  "${WEBRTC_QOS_PLAY_TARGET}")

add_executable(minimal_udp_selftest selftest/main.cc)
target_link_libraries(minimal_udp_selftest PRIVATE
  minimal_udp_common
  "${WEBRTC_QOS_PUSH_TARGET}"
  "${WEBRTC_QOS_PLAY_TARGET}"
  "${WEBRTC_QOS_SERVER_TARGET}")
