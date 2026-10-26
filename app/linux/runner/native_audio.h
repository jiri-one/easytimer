#ifndef EASYTIMER_NATIVE_AUDIO_H_
#define EASYTIMER_NATIVE_AUDIO_H_

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

class NativeAudio {
 public:
  enum class Sound { kNone, kAlarm, kEnd };
  using Completion = std::function<void(bool)>;
  using PlaybackCompletion = std::function<void(int64_t)>;
  struct Request {
    std::string event_id;
    int64_t generation = 0;
    int64_t alarm_generation = 0;
    int64_t deadline_ms = 0;
    int64_t planned_at_ms = 0;
  };

  NativeAudio();
  ~NativeAudio();
  NativeAudio(const NativeAudio&) = delete;
  NativeAudio& operator=(const NativeAudio&) = delete;

  void Initialize(std::vector<uint8_t> alarm, std::vector<uint8_t> end,
                  Completion complete);
  void Play(Sound sound, Request request, PlaybackCompletion complete);
  void Stop(int64_t generation, int64_t alarm_generation,
            bool alarm_only = false);
  void BeginWorkout(int64_t generation, int64_t alarm_generation);
  void SetVolume(double gain);
  static int64_t NowMs();

 private:
  struct State;
  std::unique_ptr<State> state_;
};

#endif
