#ifndef EASYTIMER_NATIVE_AUDIO_H_
#define EASYTIMER_NATIVE_AUDIO_H_

#include <cstdint>
#include <functional>
#include <memory>
#include <vector>

class NativeAudio {
 public:
  enum class Sound { kNone, kAlarm, kEnd };
  using Completion = std::function<void(bool)>;

  NativeAudio();
  ~NativeAudio();
  NativeAudio(const NativeAudio&) = delete;
  NativeAudio& operator=(const NativeAudio&) = delete;

  void Initialize(std::vector<uint8_t> alarm, std::vector<uint8_t> end,
                  Completion complete);
  void Play(Sound sound, Completion complete);
  void Stop(bool alarm_only = false);
  void SetVolume(double gain);

 private:
  struct State;
  std::shared_ptr<State> state_;
};

#endif
