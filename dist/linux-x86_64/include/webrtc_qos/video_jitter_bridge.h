#pragma once

#include <memory>

#include "webrtc_qos/video_jitter_player.h"

namespace webrtc_qos {

std::unique_ptr<VideoJitterBackend> CreateWebRtcVideoJitterBackend(
    const VideoJitterPlayerConfig& config);

VideoJitterPlayer CreateWebRtcVideoJitterPlayer(
    const VideoJitterPlayerConfig& config);

}  // namespace webrtc_qos
