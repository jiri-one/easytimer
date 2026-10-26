#include "native_audio.h"

#include <dlfcn.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <mutex>
#include <thread>
#include <utility>

namespace {

uint16_t Read16(const uint8_t* bytes) {
  return bytes[0] | (static_cast<uint16_t>(bytes[1]) << 8);
}

uint32_t Read32(const uint8_t* bytes) {
  return Read16(bytes) | (static_cast<uint32_t>(Read16(bytes + 2)) << 16);
}

struct Wav {
  uint32_t rate = 0;
  uint8_t channels = 0;
  std::vector<int16_t> samples;
};

bool DecodeWav(const std::vector<uint8_t>& bytes, Wav* wav) {
  if (bytes.size() < 12 || bytes.size() > 16 * 1024 * 1024 ||
      std::memcmp(bytes.data(), "RIFF", 4) != 0 ||
      std::memcmp(bytes.data() + 8, "WAVE", 4) != 0) {
    return false;
  }
  const uint64_t end = static_cast<uint64_t>(Read32(bytes.data() + 4)) + 8;
  if (end < 12 || end > bytes.size()) return false;
  Wav decoded;
  size_t data_offset = 0;
  size_t data_size = 0;
  size_t offset = 12;
  while (offset + 8 <= end) {
    const auto* chunk = bytes.data() + offset;
    const size_t size = Read32(chunk + 4);
    offset += 8;
    if (size > end - offset) return false;
    const auto* data = bytes.data() + offset;
    if (std::memcmp(chunk, "fmt ", 4) == 0) {
      if (decoded.rate != 0 || size < 16 || Read16(data) != 1 ||
          Read16(data + 14) != 16) {
        return false;
      }
      const auto channels = Read16(data + 2);
      decoded.rate = Read32(data + 4);
      if (channels < 1 || channels > 2 || decoded.rate == 0 ||
          decoded.rate > 384000 || Read16(data + 12) != channels * 2 ||
          Read32(data + 8) != decoded.rate * channels * 2) {
        return false;
      }
      decoded.channels = static_cast<uint8_t>(channels);
    } else if (std::memcmp(chunk, "data", 4) == 0) {
      if (data_offset != 0) return false;
      data_offset = offset;
      data_size = size;
    }
    offset += size + (size & 1);
  }
  if (offset != end || decoded.rate == 0 || data_size == 0 ||
      data_size % (decoded.channels * 2) != 0) {
    return false;
  }
  decoded.samples.reserve(data_size / 2);
  for (size_t i = data_offset; i < data_offset + data_size; i += 2) {
    const int value = Read16(bytes.data() + i);
    decoded.samples.push_back(value >= 32768 ? value - 65536 : value);
  }
  *wav = std::move(decoded);
  return true;
}

// The stable libpulse-simple ABI avoids a build-time PulseAudio dependency.
struct PulseStream;
constexpr int kPulseSampleS16LE = 3;
constexpr int kPulseStreamPlayback = 1;
struct PulseSampleSpec {
  int format;
  uint32_t rate;
  uint8_t channels;
};
struct PulseBufferAttr {
  uint32_t maxlength, tlength, prebuf, minreq, fragsize;
};

class Pulse {
 public:
  ~Pulse() {
    if (library_) dlclose(library_);
  }

  bool Load() {
    if (library_) return true;
    library_ = dlopen("libpulse-simple.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!library_) return false;
    const bool loaded =
        Symbol(&open, "pa_simple_new") && Symbol(&write, "pa_simple_write") &&
        Symbol(&drain, "pa_simple_drain") &&
        Symbol(&flush, "pa_simple_flush") && Symbol(&free, "pa_simple_free");
    if (!loaded) {
      dlclose(library_);
      library_ = nullptr;
    }
    return loaded;
  }

  PulseStream* (*open)(const char*, const char*, int, const char*, const char*,
                       const PulseSampleSpec*, const void*,
                       const PulseBufferAttr*, int*) = nullptr;
  int (*write)(PulseStream*, const void*, size_t, int*) = nullptr;
  int (*drain)(PulseStream*, int*) = nullptr;
  int (*flush)(PulseStream*, int*) = nullptr;
  void (*free)(PulseStream*) = nullptr;

 private:
  template <typename T>
  bool Symbol(T* target, const char* name) {
    *target = reinterpret_cast<T>(dlsym(library_, name));
    return *target != nullptr;
  }

  void* library_ = nullptr;
};

}  // namespace

struct NativeAudio::State {
  struct Command {
    Sound sound;
    uint64_t generation = 0;
    Completion complete;
    std::vector<uint8_t> alarm_bytes;
    std::vector<uint8_t> end_bytes;
  };

  std::mutex mutex;
  std::condition_variable wake;
  std::deque<Command> commands;
  std::atomic<uint64_t> generation{0};
  std::atomic<double> gain{1.0};
  std::atomic<bool> closing{false};
  Sound requested = Sound::kNone;
  Wav alarm;
  Wav end;
  Pulse pulse;

  void Submit(Command command) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      command.generation = ++generation;
      requested = command.sound;
      commands.push_back(std::move(command));
    }
    wake.notify_one();
  }

  bool Cancelled(const Command& command) const {
    return closing || generation != command.generation;
  }

  void Play(const Command& command) {
    const Wav& wav = command.sound == Sound::kAlarm ? alarm : end;
    if (wav.samples.empty() || Cancelled(command) || !pulse.Load()) {
      command.complete(false);
      return;
    }
    const size_t chunk_samples = std::max(1u, wav.rate / 100) * wav.channels;
    const uint32_t chunk_bytes = static_cast<uint32_t>(chunk_samples * 2);
    const PulseSampleSpec spec{kPulseSampleS16LE, wav.rate, wav.channels};
    const PulseBufferAttr buffer{chunk_bytes * 4, chunk_bytes * 4, chunk_bytes,
                                 chunk_bytes, UINT32_MAX};
    auto* stream =
        pulse.open(nullptr, "EasyTimer", kPulseStreamPlayback, nullptr,
                   command.sound == Sound::kAlarm ? "Alarm" : "End", &spec,
                   nullptr, &buffer, nullptr);
    if (!stream) {
      command.complete(false);
      return;
    }
    std::vector<uint8_t> scaled(chunk_bytes);
    bool started = false;
    bool failed = false;
    const int repeats = command.sound == Sound::kEnd ? 3 : 1;
    for (int repeat = 0; repeat < repeats && !failed; ++repeat) {
      for (size_t offset = 0; offset < wav.samples.size();) {
        if (Cancelled(command)) {
          failed = true;
          break;
        }
        const size_t count =
            std::min(chunk_samples, wav.samples.size() - offset);
        const double volume = gain.load();
        for (size_t i = 0; i < count; ++i) {
          const auto sample =
              static_cast<int16_t>(wav.samples[offset + i] * volume);
          const auto bits = static_cast<uint16_t>(sample);
          scaled[i * 2] = static_cast<uint8_t>(bits);
          scaled[i * 2 + 1] = static_cast<uint8_t>(bits >> 8);
        }
        if (pulse.write(stream, scaled.data(), count * 2, nullptr) < 0 ||
            Cancelled(command)) {
          failed = true;
          break;
        }
        if (!started) {
          started = true;
          command.complete(true);
        }
        offset += count;
      }
    }
    if (failed || Cancelled(command)) {
      pulse.flush(stream, nullptr);
    } else {
      pulse.drain(stream, nullptr);
    }
    pulse.free(stream);
    if (!started) command.complete(false);
  }

  void Run() {
    for (;;) {
      Command command;
      {
        std::unique_lock<std::mutex> lock(mutex);
        wake.wait(lock, [&] { return closing || !commands.empty(); });
        if (commands.empty()) return;
        command = std::move(commands.front());
        commands.pop_front();
      }
      if (closing) {
        command.complete(false);
      } else if (command.sound == Sound::kNone) {
        alarm = Wav{};
        end = Wav{};
        const bool loaded = DecodeWav(command.alarm_bytes, &alarm) &&
                            DecodeWav(command.end_bytes, &end) && pulse.Load();
        if (!loaded) {
          alarm = Wav{};
          end = Wav{};
        }
        command.complete(loaded && !closing);
      } else {
        Play(command);
      }
      std::lock_guard<std::mutex> lock(mutex);
      if (generation == command.generation) requested = Sound::kNone;
    }
  }
};

NativeAudio::NativeAudio() : state_(std::make_shared<State>()) {
  // A blocked audio server must never hold up GTK, including during shutdown.
  std::thread([state = state_] { state->Run(); }).detach();
}

NativeAudio::~NativeAudio() {
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->closing = true;
    ++state_->generation;
  }
  state_->wake.notify_one();
}

void NativeAudio::Initialize(std::vector<uint8_t> alarm,
                             std::vector<uint8_t> end, Completion complete) {
  state_->Submit(
      {Sound::kNone, 0, std::move(complete), std::move(alarm), std::move(end)});
}

void NativeAudio::Play(Sound sound, Completion complete) {
  state_->Submit({sound, 0, std::move(complete), {}, {}});
}

void NativeAudio::Stop(bool alarm_only) {
  std::lock_guard<std::mutex> lock(state_->mutex);
  if (!alarm_only || state_->requested == Sound::kAlarm) {
    ++state_->generation;
    state_->requested = Sound::kNone;
  }
}

void NativeAudio::SetVolume(double gain) {
  if (std::isfinite(gain)) state_->gain = std::max(0.0, std::min(1.0, gain));
}
