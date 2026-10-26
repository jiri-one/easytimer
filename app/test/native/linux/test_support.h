#ifndef EASYTIMER_TEST_SUPPORT_H_
#define EASYTIMER_TEST_SUPPORT_H_

#include <atomic>
#include <chrono>
#include <fstream>
#include <future>
#include <iterator>
#include <memory>
#include <stdexcept>
#include <thread>

#include "native_audio.h"

inline void Check(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

template <typename Predicate>
void Wait(Predicate predicate, const char* message, int timeout_ms = 1500) {
  const auto until =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  while (!predicate()) {
    Check(std::chrono::steady_clock::now() < until, message);
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
}

inline std::vector<uint8_t> TestWav() {
  std::vector<uint8_t> result;
  auto four = [&](const char* text) {
    result.insert(result.end(), text, text + 4);
  };
  auto le16 = [&](uint16_t n) {
    result.push_back(n);
    result.push_back(n >> 8);
  };
  auto le32 = [&](uint32_t n) {
    le16(n);
    le16(n >> 16);
  };
  four("RIFF");
  le32(236);
  four("WAVE");
  four("fmt ");
  le32(16);
  le16(1);
  le16(1);
  le32(1000);
  le32(2000);
  le16(2);
  le16(16);
  four("data");
  le32(200);
  for (int i = 0; i < 100; ++i) le16(10000);
  return result;
}

inline std::vector<uint8_t> LoadWav(const char* path) {
  std::ifstream input(path, std::ios::binary);
  Check(input.good(), "WAV asset missing");
  return {std::istreambuf_iterator<char>(input),
          std::istreambuf_iterator<char>()};
}

inline std::unique_ptr<NativeAudio> Initialize(bool assets = false) {
  auto audio = std::make_unique<NativeAudio>();
  auto result = std::make_shared<std::promise<bool>>();
  auto future = result->get_future();
  audio->Initialize(
      assets ? LoadWav("app/assets/audio/threesecbeep.wav") : TestWav(),
      assets ? LoadWav("app/assets/audio/hit.wav") : TestWav(),
      [result](bool success) { result->set_value(success); });
  Check(future.wait_for(std::chrono::seconds(2)) == std::future_status::ready &&
            future.get(),
        "initialize failed");
  return audio;
}

struct Reply {
  std::shared_ptr<std::atomic<int>> calls =
      std::make_shared<std::atomic<int>>(0);
  std::shared_ptr<std::promise<int64_t>> promise =
      std::make_shared<std::promise<int64_t>>();
  std::future<int64_t> future = promise->get_future();
  NativeAudio::PlaybackCompletion callback() const {
    return [count = calls, result = promise](int64_t time) {
      if (++*count == 1) result->set_value(time);
    };
  }
  int64_t Get() {
    Check(future.wait_for(std::chrono::seconds(2)) == std::future_status::ready,
          "playback reply stuck");
    return future.get();
  }
};

inline NativeAudio::Request Request(std::string id, int64_t generation = 0,
                                    int64_t alarm_generation = 0,
                                    int deadline_ms = 5000,
                                    int64_t planned_at_ms = -1) {
  const int64_t now = NativeAudio::NowMs();
  return {std::move(id), generation, alarm_generation, now + deadline_ms,
          planned_at_ms < 0 ? now : planned_at_ms};
}

inline void Until(int64_t time) {
  Wait([&] { return NativeAudio::NowMs() >= time; }, "clock failed to advance",
       5000);
}
#endif
