#pragma once

#include <memory>

#include "webrtc_qos/sender_qos_controller.h"

namespace webrtc_qos {

std::unique_ptr<SenderQosBackend> CreateGoogCcSenderQosBackend(
    const SenderQosControllerConfig& config,
    int64_t start_time_us);

SenderQosController CreateGoogCcSenderQosController(
    const SenderQosControllerConfig& config,
    int64_t start_time_us);

}  // namespace webrtc_qos
