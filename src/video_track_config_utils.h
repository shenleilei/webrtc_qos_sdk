#pragma once

#include <cstdint>
#include <unordered_set>
#include <vector>

#include "webrtc_qos/session_config.h"
#include "webrtc_qos/status.h"

namespace webrtc_qos {

inline Status ResolveVideoTrackConfigs(const SessionConfig& session,
                                       std::vector<VideoTrackConfig>* out) {
  if (out == nullptr) {
    return Status::Error(StatusCode::kInvalidArgument,
                         "missing output vector for video tracks");
  }
  out->clear();

  if (session.video_tracks.empty()) {
    VideoTrackConfig track;
    track.ids = session.ids;
    track.h264 = session.h264;
    track.base_track = true;
    if (track.ids.source_id == 0) {
      track.ids.source_id = session.ids.stream_id;
    }
    if (track.ids.track_id == 0) {
      track.ids.track_id = 1;
    }
    if (track.ids.sender_ssrc == 0) {
      return Status::Error(StatusCode::kInvalidArgument,
                           "single-track session requires sender_ssrc");
    }
    out->push_back(track);
    return Status::Ok();
  }

  std::unordered_set<uint32_t> seen_track_ids;
  std::unordered_set<uint32_t> seen_sender_ssrcs;
  bool saw_base_track = false;
  for (size_t i = 0; i < session.video_tracks.size(); ++i) {
    VideoTrackConfig track = session.video_tracks[i];
    if (track.ids.session_id == 0) {
      track.ids.session_id = session.ids.session_id;
    }
    if (track.ids.stream_id == 0) {
      track.ids.stream_id = session.ids.stream_id;
    }
    if (track.ids.transport_id == 0) {
      track.ids.transport_id = session.ids.transport_id;
    }
    if (track.ids.source_id == 0) {
      track.ids.source_id = session.ids.source_id != 0 ? session.ids.source_id
                                                       : session.ids.stream_id;
    }
    if (track.ids.track_id == 0) {
      track.ids.track_id = static_cast<uint32_t>(i + 1);
    }
    if (track.ids.sender_ssrc == 0) {
      if (i == 0 && session.ids.sender_ssrc != 0) {
        track.ids.sender_ssrc = session.ids.sender_ssrc;
      } else {
        track.ids.sender_ssrc =
            0x40000000u + static_cast<uint32_t>(i + 1);
      }
    }
    if (track.weight == 0) {
      track.weight = 100;
    }
    if (track.base_track) {
      saw_base_track = true;
    }
    if (!seen_track_ids.insert(track.ids.track_id).second) {
      return Status::Error(StatusCode::kInvalidArgument,
                           "duplicate track_id in video_tracks");
    }
    if (!seen_sender_ssrcs.insert(track.ids.sender_ssrc).second) {
      return Status::Error(StatusCode::kInvalidArgument,
                           "duplicate sender_ssrc in video_tracks");
    }
    out->push_back(track);
  }

  if (!saw_base_track && !out->empty()) {
    out->front().base_track = true;
  }
  return Status::Ok();
}

inline uint32_t PrimaryTrackId(const std::vector<VideoTrackConfig>& tracks) {
  for (const auto& track : tracks) {
    if (track.base_track) {
      return track.ids.track_id;
    }
  }
  return tracks.empty() ? 0 : tracks.front().ids.track_id;
}

}  // namespace webrtc_qos
