#include "native_audio.h"

#include <dlfcn.h>
#include <pulse/pulseaudio.h>
#include <time.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <set>
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

class Pulse {
 public:
  ~Pulse() {
    if (library_) dlclose(library_);
  }

#define PULSE_FUNCTIONS(X)   \
  X(mainloop_new)            \
  X(mainloop_free)           \
  X(mainloop_get_api)        \
  X(mainloop_iterate)        \
  X(context_new)             \
  X(context_connect)         \
  X(context_get_state)       \
  X(context_disconnect)      \
  X(context_unref)           \
  X(stream_new)              \
  X(stream_connect_playback) \
  X(stream_get_state)        \
  X(stream_writable_size)    \
  X(stream_write)            \
  X(stream_drain)            \
  X(stream_disconnect)       \
  X(stream_unref)            \
  X(operation_get_state)     \
  X(operation_cancel)        \
  X(operation_unref)

#define DECLARE(name) decltype(&pa_##name) name = nullptr;
  PULSE_FUNCTIONS(DECLARE)
#undef DECLARE

  bool Load() {
    if (library_) return true;
    // Audio remains optional when the runtime has no PulseAudio client library.
    library_ = dlopen("libpulse.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!library_) return false;
    bool loaded = true;
#define LOAD(name) loaded = Symbol(&name, "pa_" #name) && loaded;
    PULSE_FUNCTIONS(LOAD)
#undef LOAD
#undef PULSE_FUNCTIONS
    if (!loaded) {
      dlclose(library_);
      library_ = nullptr;
    }
    return loaded;
  }

 private:
  template <typename T>
  bool Symbol(T* target, const char* name) {
    *target = reinterpret_cast<T>(dlsym(library_, name));
    return *target != nullptr;
  }
  void* library_ = nullptr;
};

struct Connection {
  explicit Connection(Pulse& api) : pulse(api) {}
  ~Connection() {
    if (drain) {
      pulse.operation_cancel(drain);
      pulse.operation_unref(drain);
    }
    if (stream) {
      pulse.stream_disconnect(stream);
      pulse.stream_unref(stream);
    }
    // Closing the socket drops buffered audio without waiting for server ACKs.
    if (context) {
      pulse.context_disconnect(context);
      pulse.context_unref(context);
    }
    if (loop) pulse.mainloop_free(loop);
  }
  Pulse& pulse;
  pa_mainloop* loop = nullptr;
  pa_context* context = nullptr;
  pa_stream* stream = nullptr;
  pa_operation* drain = nullptr;
};

constexpr int64_t kAlarmGuardMs = 3000;
constexpr int64_t kServerTimeoutMs = 1000;
constexpr auto kPollInterval = std::chrono::milliseconds(5);
}

struct NativeAudio::State {
  struct Command {
    Sound sound = Sound::kNone;
    Request request;
    uint64_t revision = 0;
    uint64_t alarm_revision = 0;
    Completion initialized;
    PlaybackCompletion complete;
    std::vector<uint8_t> alarm_bytes;
    std::vector<uint8_t> end_bytes;
  };

  std::mutex mutex;
  std::condition_variable wake;
  std::deque<Command> commands;
  std::thread worker;
  uint64_t revision = 0;
  uint64_t alarm_revision = 0;
  int64_t generation = 0;
  int64_t alarm_generation = 0;
  int64_t last_alarm_planned = -1;
  uint64_t playing_end_revision = 0;
  uint64_t preserved_end_revision = 0;
  std::map<std::string, int64_t> started;
  std::set<std::pair<int64_t, std::string>> pending;
  std::atomic<double> gain{1.0};
  bool closing = false;
  Wav alarm;
  Wav end;
  Pulse pulse;

  void AdvanceGeneration(int64_t next) {
    if (next > generation) {
      generation = next;
      started.clear();
    }
  }

  bool Stale(const Command& command, bool playing = false) const {
    if (closing) return true;
    if (playing && command.sound == Sound::kEnd &&
        command.revision == preserved_end_revision)
      return false;
    return command.revision != revision ||
           command.request.generation < generation ||
           (command.sound == Sound::kAlarm &&
            (command.alarm_revision != alarm_revision ||
             command.request.alarm_generation < alarm_generation));
  }

  bool StartAllowed(const Command& command, int64_t now) const {
    return !Stale(command) &&
           (command.sound != Sound::kAlarm ||
            (now <= command.request.deadline_ms &&
             (last_alarm_planned < 0 ||
              command.request.planned_at_ms - last_alarm_planned >=
                  kAlarmGuardMs)));
  }

  bool Cancelled(const Command& command, bool started_playing) {
    std::lock_guard<std::mutex> lock(mutex);
    return started_playing ? Stale(command, true)
                           : !StartAllowed(command, NowMs());
  }

  bool Poll(Connection& connection, const Command& command, bool playing,
            int64_t expires) {
    if (Cancelled(command, playing) || NowMs() >= expires) return false;
    const int dispatched = pulse.mainloop_iterate(connection.loop, 0, nullptr);
    if (dispatched < 0) return false;
    if (Cancelled(command, playing) || NowMs() >= expires) return false;
    if (dispatched > 0) return true;
    std::unique_lock<std::mutex> lock(mutex);
    wake.wait_for(lock, kPollInterval, [&] { return Stale(command, playing); });
    return !Stale(command, playing);
  }

  bool Healthy(const Connection& connection) const {
    return PA_CONTEXT_IS_GOOD(pulse.context_get_state(connection.context)) &&
           (!connection.stream ||
            PA_STREAM_IS_GOOD(pulse.stream_get_state(connection.stream)));
  }

  void Play(const Command& command) {
    bool played = false;
    {
      Connection connection(pulse);
      PlayConnected(command, connection, &played);
    }
    {
      std::lock_guard<std::mutex> lock(mutex);
      pending.erase({command.request.generation, command.request.event_id});
      if (playing_end_revision == command.revision) playing_end_revision = 0;
      if (preserved_end_revision == command.revision)
        preserved_end_revision = 0;
    }
    if (!played) command.complete(-1);
  }

  void PlayConnected(const Command& command, Connection& connection,
                     bool* played) {
    const Wav& wav = command.sound == Sound::kAlarm ? alarm : end;
    if (wav.samples.empty() || Cancelled(command, false) || !pulse.Load())
      return;
    connection.loop = pulse.mainloop_new();
    if (!connection.loop) return;
    connection.context =
        pulse.context_new(pulse.mainloop_get_api(connection.loop), "EasyTimer");
    if (!connection.context) return;
    // Autospawning can run external helpers; server connection must stay
    // cancellable.
    if (pulse.context_connect(connection.context, nullptr,
                              PA_CONTEXT_NOAUTOSPAWN, nullptr) < 0)
      return;
    const int64_t connect_deadline = NowMs() + kServerTimeoutMs;
    while (pulse.context_get_state(connection.context) != PA_CONTEXT_READY) {
      if (!Healthy(connection) ||
          !Poll(connection, command, false, connect_deadline))
        return;
    }

    const size_t frame_bytes = wav.channels * 2;
    const size_t chunk_samples = std::max(1u, wav.rate / 100) * wav.channels;
    const uint32_t chunk_bytes = static_cast<uint32_t>(chunk_samples * 2);
    const pa_sample_spec spec{PA_SAMPLE_S16LE, wav.rate, wav.channels};
    const pa_buffer_attr buffer{chunk_bytes * 4, chunk_bytes * 4, chunk_bytes,
                                chunk_bytes, UINT32_MAX};
    connection.stream = pulse.stream_new(
        connection.context, command.sound == Sound::kAlarm ? "Alarm" : "End",
        &spec, nullptr);
    if (!connection.stream ||
        pulse.stream_connect_playback(connection.stream, nullptr, &buffer,
                                      PA_STREAM_ADJUST_LATENCY, nullptr,
                                      nullptr) < 0)
      return;
    while (pulse.stream_get_state(connection.stream) != PA_STREAM_READY) {
      if (!Healthy(connection) ||
          !Poll(connection, command, false, connect_deadline))
        return;
    }

    std::vector<uint8_t> scaled(chunk_bytes);
    const size_t total_samples =
        wav.samples.size() * (command.sound == Sound::kEnd ? 3 : 1);
    int64_t progress_deadline = NowMs() + kServerTimeoutMs;
    for (size_t offset = 0; offset < total_samples;) {
      if (Cancelled(command, *played) || !Healthy(connection)) return;
      const size_t writable = pulse.stream_writable_size(connection.stream);
      if (writable == static_cast<size_t>(-1)) return;
      const size_t count = std::min({chunk_samples, total_samples - offset,
                                     (writable / frame_bytes) * wav.channels});
      if (count == 0) {
        if (!Poll(connection, command, *played, progress_deadline)) return;
        continue;
      }
      const double volume = gain.load();
      for (size_t i = 0; i < count; ++i) {
        const auto sample = static_cast<int16_t>(
            wav.samples[(offset + i) % wav.samples.size()] * volume);
        const auto bits = static_cast<uint16_t>(sample);
        scaled[i * 2] = static_cast<uint8_t>(bits);
        scaled[i * 2 + 1] = static_cast<uint8_t>(bits >> 8);
      }
      int64_t first_start = -1;
      {
        // Stop and the first nonblocking enqueue share a lock, so neither can
        // pass the other.
        std::lock_guard<std::mutex> lock(mutex);
        if (Stale(command, *played) ||
            (!*played && !StartAllowed(command, NowMs())))
          return;
        if (pulse.stream_write(connection.stream, scaled.data(), count * 2,
                               nullptr, 0, PA_SEEK_RELATIVE) < 0)
          return;
        if (!*played) {
          first_start = NowMs();
          *played = true;
          started[command.request.event_id] = first_start;
          if (command.sound == Sound::kAlarm) {
            // Scheduling jitter must not suppress adjacent cues planned 3
            // seconds apart.
            last_alarm_planned = command.request.planned_at_ms;
          } else {
            playing_end_revision = command.revision;
          }
        }
      }
      if (first_start >= 0) command.complete(first_start);
      offset += count;
      progress_deadline = NowMs() + kServerTimeoutMs;
      if (pulse.mainloop_iterate(connection.loop, 0, nullptr) < 0) return;
    }
    connection.drain = pulse.stream_drain(connection.stream, nullptr, nullptr);
    if (!connection.drain) return;
    const int64_t drain_deadline = NowMs() + kServerTimeoutMs;
    while (pulse.operation_get_state(connection.drain) ==
           PA_OPERATION_RUNNING) {
      if (!Healthy(connection) ||
          !Poll(connection, command, true, drain_deadline))
        return;
    }
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
      if (command.sound == Sound::kNone) {
        alarm = Wav{};
        end = Wav{};
        const bool loaded = !Cancelled(command, true) &&
                            DecodeWav(command.alarm_bytes, &alarm) &&
                            DecodeWav(command.end_bytes, &end) && pulse.Load();
        if (!loaded) {
          alarm = Wav{};
          end = Wav{};
        }
        command.initialized(loaded && !Cancelled(command, true));
      } else {
        Play(command);
      }
    }
  }
};

int64_t NativeAudio::NowMs() {
  timespec now{};
  clock_gettime(CLOCK_BOOTTIME, &now);
  return static_cast<int64_t>(now.tv_sec) * 1000 + now.tv_nsec / 1000000;
}

NativeAudio::NativeAudio() : state_(std::make_unique<State>()) {
  state_->worker = std::thread([this] { state_->Run(); });
}

NativeAudio::~NativeAudio() {
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->closing = true;
  }
  state_->wake.notify_one();
  state_->worker.join();
}

void NativeAudio::Initialize(std::vector<uint8_t> alarm,
                             std::vector<uint8_t> end, Completion complete) {
  State::Command command;
  command.initialized = std::move(complete);
  command.alarm_bytes = std::move(alarm);
  command.end_bytes = std::move(end);
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    command.revision = ++state_->revision;
    state_->playing_end_revision = 0;
    state_->preserved_end_revision = 0;
    command.request.generation = state_->generation;
    state_->commands.push_back(std::move(command));
  }
  state_->wake.notify_one();
}

void NativeAudio::Play(Sound sound, Request request,
                       PlaybackCompletion complete) {
  int64_t previous_start = -1;
  bool queued = false;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!state_->closing && sound != Sound::kNone &&
        !request.event_id.empty() && request.event_id.size() <= 1024 &&
        request.generation >= state_->generation &&
        request.alarm_generation >= 0 && request.deadline_ms >= 0 &&
        request.planned_at_ms >= 0 &&
        (sound != Sound::kAlarm ||
         request.alarm_generation >= state_->alarm_generation)) {
      state_->AdvanceGeneration(request.generation);
      if (sound == Sound::kAlarm)
        state_->alarm_generation = request.alarm_generation;
      const auto found = state_->started.find(request.event_id);
      if (found != state_->started.end()) {
        previous_start = found->second;
      } else {
        State::Command command;
        command.sound = sound;
        command.request = std::move(request);
        command.revision = state_->revision;
        command.alarm_revision = state_->alarm_revision;
        if (state_->StartAllowed(command, NowMs()) &&
            state_->pending
                .insert({command.request.generation, command.request.event_id})
                .second) {
          command.revision = ++state_->revision;
          state_->preserved_end_revision = 0;
          command.complete = std::move(complete);
          state_->commands.push_back(std::move(command));
          queued = true;
        }
      }
    }
  }
  state_->wake.notify_one();
  if (!queued) complete(previous_start);
}

void NativeAudio::Stop(int64_t generation, int64_t alarm_generation,
                       bool alarm_only) {
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (generation < state_->generation || alarm_generation < 0 ||
        (alarm_only && alarm_generation < state_->alarm_generation))
      return;
    state_->alarm_generation =
        std::max(state_->alarm_generation, alarm_generation);
    ++state_->alarm_revision;
    if (!alarm_only) {
      state_->AdvanceGeneration(generation);
      ++state_->revision;
      state_->playing_end_revision = 0;
      state_->preserved_end_revision = 0;
    }
  }
  state_->wake.notify_one();
}

void NativeAudio::BeginWorkout(int64_t generation, int64_t alarm_generation) {
  std::deque<State::Command> cancelled;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (generation < state_->generation ||
        alarm_generation < state_->alarm_generation)
      return;
    state_->AdvanceGeneration(generation);
    state_->alarm_generation =
        std::max(state_->alarm_generation, alarm_generation);
    ++state_->revision;
    ++state_->alarm_revision;
    state_->preserved_end_revision = state_->playing_end_revision;
    for (auto it = state_->commands.begin(); it != state_->commands.end();) {
      if (it->sound == Sound::kNone) {
        ++it;
      } else {
        state_->pending.erase({it->request.generation, it->request.event_id});
        cancelled.push_back(std::move(*it));
        it = state_->commands.erase(it);
      }
    }
  }
  state_->wake.notify_one();
  for (auto& command : cancelled) command.complete(-1);
}

void NativeAudio::SetVolume(double gain) {
  if (std::isfinite(gain)) state_->gain = std::max(0.0, std::min(1.0, gain));
}
