#include <cstdlib>
#include <iostream>

#include "test_support.h"

namespace {
using Sound = NativeAudio::Sound;
void StalledServer() {
  auto audio = Initialize();
  audio->SetVolume(0);
  Reply deadline;
  const auto begin = NativeAudio::NowMs();
  audio->Play(Sound::kAlarm, Request("deadline", 0, 0, 49),
              deadline.callback());
  Check(deadline.Get() < 0 && NativeAudio::NowMs() - begin < 250,
        "real client lost deadline while waiting for server handshake");
  Reply timeout;
  const auto waiting = NativeAudio::NowMs();
  audio->Play(Sound::kEnd, Request("timeout"), timeout.callback());
  Check(timeout.Get() < 0 && NativeAudio::NowMs() - waiting < 1400,
        "real client handshake timeout unbounded");
  Reply stopped;
  audio->Play(Sound::kEnd, Request("stop"), stopped.callback());
  Check(stopped.future.wait_for(std::chrono::milliseconds(50)) ==
            std::future_status::timeout,
        "stalled server did not hold handshake open");
  const auto stop_at = NativeAudio::NowMs();
  audio->Stop(1, 1);
  Check(stopped.Get() < 0 && NativeAudio::NowMs() - stop_at <= 50,
        "real client stop blocked on stalled server");
  Reply disposed;
  audio->Play(Sound::kEnd, Request("dispose", 1, 1), disposed.callback());
  Check(disposed.future.wait_for(std::chrono::milliseconds(50)) ==
            std::future_status::timeout,
        "subsequent request did not open another connection");
  const auto disposing = NativeAudio::NowMs();
  audio.reset();
  Check(disposed.Get() < 0 && NativeAudio::NowMs() - disposing <= 50,
        "real client dispose blocked on stalled server");
  Check(*deadline.calls == 1 && *timeout.calls == 1 && *stopped.calls == 1 &&
            *disposed.calls == 1,
        "real client replied more than once");
  std::cout << "PASS real libpulse against nonresponsive Unix socket: "
               "deadline, timeout, stop, subsequent request, dispose\n";
}

void LiveServer() {
  Check(std::getenv("PULSE_SINK") != nullptr,
        "live test requires an isolated null sink");
  auto audio = Initialize(true);
  audio->SetVolume(0);
  int64_t generation = 0;
  for (const auto sound : {Sound::kAlarm, Sound::kEnd}) {
    Reply reply;
    const auto before = NativeAudio::NowMs();
    audio->Play(sound,
                Request(sound == Sound::kAlarm ? "alarm" : "end", generation,
                        generation),
                reply.callback());
    const auto started = reply.Get();
    Check(started >= before && started <= NativeAudio::NowMs(),
          "real playback start failed");
    std::this_thread::sleep_for(std::chrono::milliseconds(80));
    const auto stopping = NativeAudio::NowMs();
    ++generation;
    audio->Stop(generation, generation);
    Check(NativeAudio::NowMs() - stopping <= 50, "real stop call blocked");
    std::cout << "PASS real libpulse "
              << (sound == Sound::kAlarm ? "alarm" : "end")
              << " start=" << started - before
              << "ms; stop returned promptly\n";
  }
  const auto disposing = NativeAudio::NowMs();
  audio.reset();
  Check(NativeAudio::NowMs() - disposing <= 50, "real dispose blocked");
}
}

int main(int argc, char** argv) {
  try {
    Check(argc == 2, "expected stalled or live scenario");
    if (std::string(argv[1]) == "stalled")
      StalledServer();
    else if (std::string(argv[1]) == "live")
      LiveServer();
    else
      Check(false, "unknown scenario");
  } catch (const std::exception& error) {
    std::cerr << "FAIL " << error.what() << '\n';
    return 1;
  }
}
