#ifndef EASYTIMER_TEST_FAKE_PULSE_H_
#define EASYTIMER_TEST_FAKE_PULSE_H_

#include <cstddef>
#include <cstdint>
#include <vector>

enum class Stall { kNone, kConnect, kStream, kWritable, kBuffered, kDrain };
struct PulsePlan {
  Stall stall = Stall::kNone;
  int connect_delay_ms = 0;
  int stream_delay_ms = 0;
  int writable_delay_ms = 0;
  bool fail_write = false;
};
struct PulseStats {
  int connects = 0;
  int streams = 0;
  int writes = 0;
  int drains = 0;
  int cancellations = 0;
  int disconnects = 0;
  int resources = 0;
  std::vector<uint8_t> pcm;
};
void FakeReset(PulsePlan plan = {});
void FakePlan(PulsePlan plan);
PulseStats FakeStats();
#endif
