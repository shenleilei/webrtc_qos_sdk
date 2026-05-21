#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK_DIR="${WORK_DIR:-/tmp/webrtc_qos_real_renderer_smoke.$$}"
OUTPUT_DIR="${OUTPUT_DIR:-${SDK_ROOT}/artifacts/webrtc_first_real_renderer_smoke}"
SUMMARY_FILE="${SUMMARY_FILE:-${OUTPUT_DIR}/real_renderer_summary.txt}"
CSV_FILE="${CSV_FILE:-${OUTPUT_DIR}/real_renderer_metrics.csv}"
REQUIRE_REAL_RENDERER="${REQUIRE_REAL_RENDERER:-0}"
USE_XVFB="${USE_XVFB:-auto}"
XVFB_DISPLAY="${XVFB_DISPLAY:-:99}"
XVFB_SCREEN="${XVFB_SCREEN:-0}"
XVFB_GEOMETRY="${XVFB_GEOMETRY:-${WIDTH:-320}x${HEIGHT:-180}x24}"
FRAMES="${FRAMES:-60}"
WIDTH="${WIDTH:-320}"
HEIGHT="${HEIGHT:-180}"
FPS="${FPS:-30}"
MAX_PRESENT_GAP_MS="${MAX_PRESENT_GAP_MS:-80}"
MAX_PRESENT_JITTER_MS="${MAX_PRESENT_JITTER_MS:-50}"
MAX_LATE_FRAMES="${MAX_LATE_FRAMES:-0}"
MAX_LATE_MS="${MAX_LATE_MS:-16}"

mkdir -p "${OUTPUT_DIR}" "${WORK_DIR}"

XVFB_PID=""
cleanup() {
  if [[ -n "${XVFB_PID}" ]]; then
    kill "${XVFB_PID}" >/dev/null 2>&1 || true
    wait "${XVFB_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

write_skip() {
  local reason="$1"
  {
    echo "real_renderer_status=skipped"
    echo "reason=${reason}"
    echo "display=${DISPLAY:-}"
    echo "wayland_display=${WAYLAND_DISPLAY:-}"
    echo "use_xvfb=${USE_XVFB}"
    echo "xvfb_available=$(command -v Xvfb >/dev/null 2>&1 && echo 1 || echo 0)"
  } >"${SUMMARY_FILE}"
  printf 'metric,value\nstatus,skipped\nreason,%s\n' "${reason}" >"${CSV_FILE}"
  if [[ "${REQUIRE_REAL_RENDERER}" == "1" ]]; then
    echo "real renderer unavailable: ${reason}" >&2
    exit 1
  fi
  cat "${SUMMARY_FILE}"
  exit 0
}

if [[ -z "${DISPLAY:-}" ]]; then
  if [[ "${USE_XVFB}" != "0" && "${USE_XVFB}" != "false" ]] &&
      command -v Xvfb >/dev/null 2>&1; then
    Xvfb "${XVFB_DISPLAY}" -screen "${XVFB_SCREEN}" "${XVFB_GEOMETRY}" \
      -nolisten tcp >"${WORK_DIR}/xvfb.log" 2>&1 &
    XVFB_PID="$!"
    export DISPLAY="${XVFB_DISPLAY}"
    sleep 0.5
    if ! kill -0 "${XVFB_PID}" >/dev/null 2>&1; then
      write_skip "Xvfb failed to start"
    fi
  else
    write_skip "DISPLAY is not set and Xvfb is not available"
  fi
fi
if ! pkg-config --exists x11; then
  write_skip "x11 pkg-config package is not available"
fi

cat >"${WORK_DIR}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(webrtc_qos_real_renderer_smoke LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(X11 REQUIRED)

add_executable(real_renderer_smoke main.cc)
target_link_libraries(real_renderer_smoke PRIVATE X11::X11)
EOF

cat >"${WORK_DIR}/main.cc" <<'EOF'
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#include <X11/Xlib.h>

namespace {

int Arg(int argc, char** argv, int index, int fallback) {
  if (argc <= index) {
    return fallback;
  }
  return std::max(0, std::atoi(argv[index]));
}

}  // namespace

int main(int argc, char** argv) {
  const int frames = std::max(1, Arg(argc, argv, 1, 60));
  const int width = std::max(2, Arg(argc, argv, 2, 320));
  const int height = std::max(2, Arg(argc, argv, 3, 180));
  const int fps = std::max(1, Arg(argc, argv, 4, 30));
  const int max_gap_ms = std::max(1, Arg(argc, argv, 5, 80));
  const int max_jitter_ms = std::max(0, Arg(argc, argv, 6, 50));
  const int max_late_frames = Arg(argc, argv, 7, 0);
  const int max_late_ms = std::max(0, Arg(argc, argv, 8, 16));

  Display* display = XOpenDisplay(nullptr);
  if (!display) {
    std::cerr << "XOpenDisplay failed\n";
    return 2;
  }

  const int screen = DefaultScreen(display);
  Window root = RootWindow(display, screen);
  Window window = XCreateSimpleWindow(
      display, root, 0, 0, static_cast<unsigned int>(width),
      static_cast<unsigned int>(height), 0, BlackPixel(display, screen),
      BlackPixel(display, screen));
  XStoreName(display, window, "webrtc_qos_real_renderer_smoke");
  XMapWindow(display, window);
  XFlush(display);
  GC gc = XCreateGC(display, window, 0, nullptr);

  using Clock = std::chrono::steady_clock;
  const auto frame_interval =
      std::chrono::microseconds(1000000 / std::max(1, fps));
  const auto start = Clock::now() + std::chrono::milliseconds(50);
  auto last_present = Clock::time_point{};
  int rendered = 0;
  int late_frames = 0;
  int max_present_gap = 0;
  int max_present_jitter = 0;
  int64_t total_present_gap_us = 0;
  int64_t total_present_jitter_us = 0;
  int gap_count = 0;

  for (int frame = 0; frame < frames; ++frame) {
    const auto target = start + frame_interval * frame;
    std::this_thread::sleep_until(target);
    const auto before_present = Clock::now();
    const auto late_us =
        std::chrono::duration_cast<std::chrono::microseconds>(before_present -
                                                              target)
            .count();
    if (late_us > static_cast<int64_t>(max_late_ms) * 1000) {
      ++late_frames;
    }

    const unsigned long color =
        ((frame * 37) % 256) << 16 | ((frame * 73) % 256) << 8 |
        ((frame * 19) % 256);
    XSetForeground(display, gc, color);
    XFillRectangle(display, window, gc, 0, 0,
                   static_cast<unsigned int>(width),
                   static_cast<unsigned int>(height));
    XFlush(display);
    XSync(display, False);
    const auto presented = Clock::now();

    if (last_present.time_since_epoch().count() != 0) {
      const auto gap_us =
          std::chrono::duration_cast<std::chrono::microseconds>(presented -
                                                                last_present)
              .count();
      const int gap_ms = static_cast<int>((gap_us + 999) / 1000);
      const int jitter_ms = std::abs(gap_ms - (1000 / fps));
      max_present_gap = std::max(max_present_gap, gap_ms);
      max_present_jitter = std::max(max_present_jitter, jitter_ms);
      total_present_gap_us += gap_us;
      total_present_jitter_us += std::llabs(
          gap_us -
          std::chrono::duration_cast<std::chrono::microseconds>(frame_interval)
              .count());
      ++gap_count;
    }
    last_present = presented;
    ++rendered;
  }

  XFreeGC(display, gc);
  XDestroyWindow(display, window);
  XCloseDisplay(display);

  const double avg_gap_ms =
      gap_count == 0 ? 0.0 : total_present_gap_us / 1000.0 / gap_count;
  const double avg_jitter_ms =
      gap_count == 0 ? 0.0 : total_present_jitter_us / 1000.0 / gap_count;
  const bool pass = rendered == frames && late_frames <= max_late_frames &&
                    max_present_gap <= max_gap_ms &&
                    max_present_jitter <= max_jitter_ms;

  std::cout << "real_renderer_status=" << (pass ? "pass" : "fail") << "\n";
  std::cout << "frames=" << frames << "\n";
  std::cout << "rendered_frames=" << rendered << "\n";
  std::cout << "late_frames=" << late_frames << "\n";
  std::cout << "max_late_frames=" << max_late_frames << "\n";
  std::cout << "avg_present_gap_ms=" << avg_gap_ms << "\n";
  std::cout << "max_present_gap_ms=" << max_present_gap << "\n";
  std::cout << "max_present_gap_budget_ms=" << max_gap_ms << "\n";
  std::cout << "avg_present_jitter_ms=" << avg_jitter_ms << "\n";
  std::cout << "max_present_jitter_ms=" << max_present_jitter << "\n";
  std::cout << "max_present_jitter_budget_ms=" << max_jitter_ms << "\n";
  return pass ? 0 : 1;
}
EOF

cmake -S "${WORK_DIR}" -B "${WORK_DIR}/build" >/dev/null
cmake --build "${WORK_DIR}/build" -j2 >/dev/null

if ! "${WORK_DIR}/build/real_renderer_smoke" \
    "${FRAMES}" "${WIDTH}" "${HEIGHT}" "${FPS}" \
    "${MAX_PRESENT_GAP_MS}" "${MAX_PRESENT_JITTER_MS}" \
    "${MAX_LATE_FRAMES}" "${MAX_LATE_MS}" >"${SUMMARY_FILE}"; then
  cat "${SUMMARY_FILE}" >&2
  exit 1
fi

{
  echo "display=${DISPLAY:-}"
  echo "renderer_backend=$([[ -n "${XVFB_PID}" ]] && echo xvfb || echo x11)"
  echo "xvfb_pid=${XVFB_PID}"
} >>"${SUMMARY_FILE}"

python3 - "${SUMMARY_FILE}" "${CSV_FILE}" <<'PY'
import sys

summary_path, csv_path = sys.argv[1], sys.argv[2]
rows = []
with open(summary_path, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        rows.append((key, value))

with open(csv_path, "w", encoding="utf-8") as f:
    f.write("metric,value\n")
    for key, value in rows:
        f.write("%s,%s\n" % (key, value))
PY

cat "${SUMMARY_FILE}"
