
####### Expanded from @PACKAGE_INIT@ by configure_package_config_file() #######
####### Any changes to this file will be overwritten by the next CMake run ####
####### The input file was WebRtcQosSdkConfig.cmake.in                            ########

get_filename_component(PACKAGE_PREFIX_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../" ABSOLUTE)

macro(set_and_check _var _file)
  set(${_var} "${_file}")
  if(NOT EXISTS "${_file}")
    message(FATAL_ERROR "File or directory ${_file} referenced by variable ${_var} does not exist !")
  endif()
endmacro()

macro(check_required_components _NAME)
  foreach(comp ${${_NAME}_FIND_COMPONENTS})
    if(NOT ${_NAME}_${comp}_FOUND)
      if(${_NAME}_FIND_REQUIRED_${comp})
        set(${_NAME}_FOUND FALSE)
      endif()
    endif()
  endforeach()
endmacro()

####################################################################################

include(CMakeFindDependencyMacro)
find_dependency(Threads)

include("${CMAKE_CURRENT_LIST_DIR}/WebRtcQosSdkTargets.cmake")

function(_webrtc_qos_sdk_add_optional_archive target archive)
  if(NOT TARGET "${target}" AND EXISTS "${PACKAGE_PREFIX_DIR}/lib/${archive}")
    add_library("${target}" STATIC IMPORTED)
    set_target_properties("${target}" PROPERTIES
      IMPORTED_LOCATION "${PACKAGE_PREFIX_DIR}/lib/${archive}"
      INTERFACE_INCLUDE_DIRECTORIES "${PACKAGE_PREFIX_DIR}/include")
  endif()
endfunction()

_webrtc_qos_sdk_add_optional_archive(
  WebRtcQosSdk::webrtc_qos_googcc_adapter
  libwebrtc_qos_googcc_adapter.a)
_webrtc_qos_sdk_add_optional_archive(
  WebRtcQosSdk::webrtc_qos_googcc_bridge
  libwebrtc_qos_googcc_bridge.a)
_webrtc_qos_sdk_add_optional_archive(
  WebRtcQosSdk::webrtc_qos_video_jitter_adapter
  libwebrtc_qos_video_jitter_adapter.a)
_webrtc_qos_sdk_add_optional_archive(
  WebRtcQosSdk::webrtc_qos_video_jitter_bridge
  libwebrtc_qos_video_jitter_bridge.a)

function(_webrtc_qos_sdk_add_optional_ffmpeg_archive target archive)
  if(TARGET "${target}" OR NOT EXISTS "${PACKAGE_PREFIX_DIR}/lib/${archive}")
    return()
  endif()

  set(_missing_dep FALSE)
  foreach(_dep IN LISTS ARGN)
    if(NOT _dep OR _dep MATCHES "-NOTFOUND$")
      set(_missing_dep TRUE)
    endif()
  endforeach()

  if(_missing_dep)
    return()
  endif()

  add_library("${target}" STATIC IMPORTED)
  set_target_properties("${target}" PROPERTIES
    IMPORTED_LOCATION "${PACKAGE_PREFIX_DIR}/lib/${archive}"
    INTERFACE_INCLUDE_DIRECTORIES "${PACKAGE_PREFIX_DIR}/include"
    INTERFACE_LINK_LIBRARIES "${ARGN}")
endfunction()

find_library(WebRtcQosSdk_AVCODEC_LIBRARY NAMES avcodec)
find_library(WebRtcQosSdk_AVUTIL_LIBRARY NAMES avutil)
find_library(WebRtcQosSdk_SWSCALE_LIBRARY NAMES swscale)

_webrtc_qos_sdk_add_optional_ffmpeg_archive(
  WebRtcQosSdk::webrtc_qos_ffmpeg_encoder
  libwebrtc_qos_ffmpeg_encoder.a
  "${WebRtcQosSdk_AVCODEC_LIBRARY}"
  "${WebRtcQosSdk_AVUTIL_LIBRARY}")
_webrtc_qos_sdk_add_optional_ffmpeg_archive(
  WebRtcQosSdk::webrtc_qos_ffmpeg_decoder
  libwebrtc_qos_ffmpeg_decoder.a
  "${WebRtcQosSdk_AVCODEC_LIBRARY}"
  "${WebRtcQosSdk_AVUTIL_LIBRARY}"
  "${WebRtcQosSdk_SWSCALE_LIBRARY}")

function(_webrtc_qos_sdk_have_targets out_var)
  set(_found TRUE)
  foreach(_target IN LISTS ARGN)
    if(NOT TARGET "${_target}")
      set(_found FALSE)
    endif()
  endforeach()
  set("${out_var}" "${_found}" PARENT_SCOPE)
endfunction()

function(_webrtc_qos_sdk_add_role target)
  if(NOT TARGET "${target}")
    add_library("${target}" INTERFACE IMPORTED)
    set_target_properties("${target}" PROPERTIES
      INTERFACE_LINK_LIBRARIES "${ARGN}")
  endif()
endfunction()

_webrtc_qos_sdk_add_role(WebRtcQosSdk::role_transport
  WebRtcQosSdk::webrtc_qos_transport)

_webrtc_qos_sdk_add_role(WebRtcQosSdk::role_server
  WebRtcQosSdk::webrtc_qos_rtp
  WebRtcQosSdk::webrtc_qos_rtcp
  WebRtcQosSdk::webrtc_qos_feedback
  WebRtcQosSdk::webrtc_qos_nack)

_webrtc_qos_sdk_have_targets(_webrtc_qos_sdk_can_add_push_role
  WebRtcQosSdk::webrtc_qos_googcc_bridge
  WebRtcQosSdk::webrtc_qos_googcc_adapter)
if(_webrtc_qos_sdk_can_add_push_role)
  _webrtc_qos_sdk_add_role(WebRtcQosSdk::role_push
    WebRtcQosSdk::webrtc_qos_googcc_bridge
    WebRtcQosSdk::webrtc_qos_video
    WebRtcQosSdk::webrtc_qos_pacer
    WebRtcQosSdk::webrtc_qos_feedback
    WebRtcQosSdk::webrtc_qos_nack
    WebRtcQosSdk::webrtc_qos_rtcp
    WebRtcQosSdk::webrtc_qos_rtp
    WebRtcQosSdk::webrtc_qos_core
    WebRtcQosSdk::webrtc_qos_googcc_adapter
    Threads::Threads
    dl
    rt
    atomic)
endif()

_webrtc_qos_sdk_have_targets(_webrtc_qos_sdk_can_add_play_role
  WebRtcQosSdk::webrtc_qos_video_jitter_bridge
  WebRtcQosSdk::webrtc_qos_video_jitter_adapter)
if(_webrtc_qos_sdk_can_add_play_role)
  _webrtc_qos_sdk_add_role(WebRtcQosSdk::role_play
    WebRtcQosSdk::webrtc_qos_video_jitter_bridge
    WebRtcQosSdk::webrtc_qos_video
    WebRtcQosSdk::webrtc_qos_nack
    WebRtcQosSdk::webrtc_qos_feedback
    WebRtcQosSdk::webrtc_qos_rtcp
    WebRtcQosSdk::webrtc_qos_rtp
    WebRtcQosSdk::webrtc_qos_core
    WebRtcQosSdk::webrtc_qos_video_jitter_adapter
    Threads::Threads
    dl
    rt
    atomic)
endif()

_webrtc_qos_sdk_have_targets(_webrtc_qos_sdk_can_add_prototype_role
  WebRtcQosSdk::webrtc_qos_googcc_bridge
  WebRtcQosSdk::webrtc_qos_googcc_adapter
  WebRtcQosSdk::webrtc_qos_video_jitter_bridge
  WebRtcQosSdk::webrtc_qos_video_jitter_adapter)
if(_webrtc_qos_sdk_can_add_prototype_role)
  _webrtc_qos_sdk_add_role(WebRtcQosSdk::role_prototype
    WebRtcQosSdk::webrtc_qos
    WebRtcQosSdk::webrtc_qos_googcc_bridge
    WebRtcQosSdk::webrtc_qos_googcc_adapter
    WebRtcQosSdk::webrtc_qos_video_jitter_bridge
    WebRtcQosSdk::webrtc_qos_video_jitter_adapter
    Threads::Threads
    dl
    rt
    atomic)
endif()

set(WebRtcQosSdk_FOUND TRUE)
