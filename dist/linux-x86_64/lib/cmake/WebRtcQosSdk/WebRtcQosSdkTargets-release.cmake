#----------------------------------------------------------------
# Generated CMake target import file for configuration "Release".
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "WebRtcQosSdk::webrtc_qos" for configuration "Release"
set_property(TARGET WebRtcQosSdk::webrtc_qos APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(WebRtcQosSdk::webrtc_qos PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "CXX"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libwebrtc_qos.a"
  )

list(APPEND _cmake_import_check_targets WebRtcQosSdk::webrtc_qos )
list(APPEND _cmake_import_check_files_for_WebRtcQosSdk::webrtc_qos "${_IMPORT_PREFIX}/lib/libwebrtc_qos.a" )

# Import target "WebRtcQosSdk::webrtc_qos_core" for configuration "Release"
set_property(TARGET WebRtcQosSdk::webrtc_qos_core APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(WebRtcQosSdk::webrtc_qos_core PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "CXX"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libwebrtc_qos_core.a"
  )

list(APPEND _cmake_import_check_targets WebRtcQosSdk::webrtc_qos_core )
list(APPEND _cmake_import_check_files_for_WebRtcQosSdk::webrtc_qos_core "${_IMPORT_PREFIX}/lib/libwebrtc_qos_core.a" )

# Import target "WebRtcQosSdk::webrtc_qos_transport" for configuration "Release"
set_property(TARGET WebRtcQosSdk::webrtc_qos_transport APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(WebRtcQosSdk::webrtc_qos_transport PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "CXX"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libwebrtc_qos_transport.a"
  )

list(APPEND _cmake_import_check_targets WebRtcQosSdk::webrtc_qos_transport )
list(APPEND _cmake_import_check_files_for_WebRtcQosSdk::webrtc_qos_transport "${_IMPORT_PREFIX}/lib/libwebrtc_qos_transport.a" )

# Import target "WebRtcQosSdk::webrtc_qos_transport_packet_history" for configuration "Release"
set_property(TARGET WebRtcQosSdk::webrtc_qos_transport_packet_history APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(WebRtcQosSdk::webrtc_qos_transport_packet_history PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "CXX"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libwebrtc_qos_transport_packet_history.a"
  )

list(APPEND _cmake_import_check_targets WebRtcQosSdk::webrtc_qos_transport_packet_history )
list(APPEND _cmake_import_check_files_for_WebRtcQosSdk::webrtc_qos_transport_packet_history "${_IMPORT_PREFIX}/lib/libwebrtc_qos_transport_packet_history.a" )

# Import target "WebRtcQosSdk::webrtc_qos_facade_video" for configuration "Release"
set_property(TARGET WebRtcQosSdk::webrtc_qos_facade_video APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(WebRtcQosSdk::webrtc_qos_facade_video PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "CXX"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libwebrtc_qos_facade_video.a"
  )

list(APPEND _cmake_import_check_targets WebRtcQosSdk::webrtc_qos_facade_video )
list(APPEND _cmake_import_check_files_for_WebRtcQosSdk::webrtc_qos_facade_video "${_IMPORT_PREFIX}/lib/libwebrtc_qos_facade_video.a" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)
