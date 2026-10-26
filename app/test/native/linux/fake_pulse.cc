#include "fake_pulse.h"

#include <pulse/pulseaudio.h>
#include <time.h>

#include <algorithm>
#include <cassert>
#include <mutex>

namespace {
std::mutex mutex;
PulsePlan plan;
PulseStats stats;
int64_t Now() {
  timespec now{};
  clock_gettime(CLOCK_BOOTTIME, &now);
  return static_cast<int64_t>(now.tv_sec) * 1000 + now.tv_nsec / 1000000;
}
void Resource(int delta) {
  std::lock_guard<std::mutex> lock(mutex);
  stats.resources += delta;
}
}

struct pa_mainloop {
  pa_mainloop_api api{};
};
struct pa_context {
  PulsePlan plan;
  int64_t ready_at = 0;
  bool disconnected = false;
};
struct pa_stream {
  pa_context* context;
  int64_t ready_at = 0;
  size_t written = 0;
  size_t capacity = 0;
};
struct pa_operation {
  pa_operation_state_t state;
};

void FakeReset(PulsePlan next) {
  std::lock_guard<std::mutex> lock(mutex);
  assert(stats.resources == 0);
  stats = PulseStats{};
  plan = next;
}
void FakePlan(PulsePlan next) {
  std::lock_guard<std::mutex> lock(mutex);
  plan = next;
}
PulseStats FakeStats() {
  std::lock_guard<std::mutex> lock(mutex);
  return stats;
}

extern "C" {
pa_mainloop* pa_mainloop_new() {
  Resource(1);
  return new pa_mainloop;
}
void pa_mainloop_free(pa_mainloop* loop) {
  delete loop;
  Resource(-1);
}
pa_mainloop_api* pa_mainloop_get_api(pa_mainloop* loop) { return &loop->api; }
int pa_mainloop_iterate(pa_mainloop*, int block, int*) {
  assert(!block);
  return 0;
}
pa_context* pa_context_new(pa_mainloop_api*, const char*) {
  std::lock_guard<std::mutex> lock(mutex);
  ++stats.resources;
  return new pa_context{plan, 0, false};
}
int pa_context_connect(pa_context* context, const char*,
                       pa_context_flags_t flags, const pa_spawn_api*) {
  assert(flags & PA_CONTEXT_NOAUTOSPAWN);
  context->ready_at = Now() + context->plan.connect_delay_ms;
  std::lock_guard<std::mutex> lock(mutex);
  ++stats.connects;
  return 0;
}
pa_context_state_t pa_context_get_state(const pa_context* context) {
  if (context->disconnected) return PA_CONTEXT_TERMINATED;
  return context->plan.stall == Stall::kConnect || Now() < context->ready_at
             ? PA_CONTEXT_CONNECTING
             : PA_CONTEXT_READY;
}
void pa_context_disconnect(pa_context* context) {
  context->disconnected = true;
  std::lock_guard<std::mutex> lock(mutex);
  ++stats.disconnects;
}
void pa_context_unref(pa_context* context) {
  delete context;
  Resource(-1);
}
pa_stream* pa_stream_new(pa_context* context, const char*,
                         const pa_sample_spec*, const pa_channel_map*) {
  std::lock_guard<std::mutex> lock(mutex);
  ++stats.resources;
  ++stats.streams;
  return new pa_stream{context, 0, 0, 0};
}
int pa_stream_connect_playback(pa_stream* stream, const char*,
                               const pa_buffer_attr* buffer,
                               pa_stream_flags_t flags, const pa_cvolume*,
                               pa_stream*) {
  assert(flags & PA_STREAM_ADJUST_LATENCY);
  assert(buffer->maxlength == buffer->tlength &&
         buffer->prebuf <= buffer->tlength);
  stream->capacity = buffer->maxlength;
  stream->ready_at = Now() + stream->context->plan.stream_delay_ms;
  return 0;
}
pa_stream_state_t pa_stream_get_state(const pa_stream* stream) {
  return stream->context->plan.stall == Stall::kStream ||
                 Now() < stream->ready_at
             ? PA_STREAM_CREATING
             : PA_STREAM_READY;
}
size_t pa_stream_writable_size(const pa_stream* stream) {
  const auto& scenario = stream->context->plan;
  if (scenario.stall == Stall::kWritable ||
      (scenario.stall == Stall::kBuffered &&
       stream->written >= stream->capacity) ||
      Now() < stream->ready_at + scenario.writable_delay_ms)
    return 0;
  return stream->capacity;
}
int pa_stream_write(pa_stream* stream, const void* data, size_t size,
                    pa_free_cb_t free_callback, int64_t offset,
                    pa_seek_mode_t seek) {
  assert(!free_callback && offset == 0 && seek == PA_SEEK_RELATIVE);
  if (stream->context->plan.fail_write) return -1;
  stream->written += size;
  const auto* bytes = static_cast<const uint8_t*>(data);
  std::lock_guard<std::mutex> lock(mutex);
  ++stats.writes;
  stats.pcm.insert(stats.pcm.end(), bytes, bytes + size);
  return 0;
}
pa_operation* pa_stream_drain(pa_stream* stream, pa_stream_success_cb_t,
                              void*) {
  std::lock_guard<std::mutex> lock(mutex);
  ++stats.resources;
  ++stats.drains;
  return new pa_operation{stream->context->plan.stall == Stall::kDrain
                              ? PA_OPERATION_RUNNING
                              : PA_OPERATION_DONE};
}
int pa_stream_disconnect(pa_stream*) { return 0; }
void pa_stream_unref(pa_stream* stream) {
  delete stream;
  Resource(-1);
}
pa_operation_state_t pa_operation_get_state(const pa_operation* operation) {
  return operation->state;
}
void pa_operation_cancel(pa_operation* operation) {
  if (operation->state == PA_OPERATION_RUNNING) {
    operation->state = PA_OPERATION_CANCELLED;
    std::lock_guard<std::mutex> lock(mutex);
    ++stats.cancellations;
  }
}
void pa_operation_unref(pa_operation* operation) {
  delete operation;
  Resource(-1);
}
}
