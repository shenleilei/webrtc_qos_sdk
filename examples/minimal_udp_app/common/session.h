#pragma once

#include <algorithm>
#include <cstdint>

#include "webrtc_qos/session_config.h"

namespace minimal_udp {

inline void AppendTrack(webrtc_qos::SessionConfig* session,
                        uint32_t track_id,
                        uint32_t sender_ssrc,
                        bool base_track,
                        uint32_t weight) {
  webrtc_qos::VideoTrackConfig track;
  track.ids = session->ids;
  track.ids.track_id = track_id;
  track.ids.sender_ssrc = sender_ssrc;
  track.base_track = base_track;
  track.weight = weight;
  session->video_tracks.push_back(track);
}

inline webrtc_qos::SessionConfig MakeSession(const char* debug_name,
                                             int tracks) {
  webrtc_qos::SessionConfig session;
  session.ids.session_id = 1;
  session.ids.stream_id = 1;
  session.ids.transport_id = 1;
  session.ids.receiver_id = 0x2222;
  session.ids.source_id = session.ids.stream_id;
  session.start_bitrate_bps = 1200000;
  session.min_bitrate_bps = 300000;
  session.max_bitrate_bps = 2500000;
  session.debug_name = debug_name;
  if (tracks <= 1) {
    AppendTrack(&session, 101, 0x12345678u, true, 100);
  } else {
    AppendTrack(&session, 101, 0x12345678u, true, 70);
    AppendTrack(&session, 202, 0x13355779u, false, 30);
  }
  session.ids.sender_ssrc = session.video_tracks.front().ids.sender_ssrc;
  return session;
}

inline bool InBadWindow(int frame, int frames) {
  return frame >= frames / 4 && frame <= frames / 2;
}

inline bool InRecoveryWindow(int frame, int frames) {
  return frame > frames / 2;
}

inline int FpsInterval(uint32_t fps) {
  if (fps >= 25) {
    return 1;
  }
  if (fps >= 15) {
    return 2;
  }
  return fps >= 10 ? 3 : 6;
}

inline double TickRate(int count, int ticks) {
  return ticks <= 0 ? 0.0 : static_cast<double>(count) * 30.0 / ticks;
}

}  // namespace minimal_udp
