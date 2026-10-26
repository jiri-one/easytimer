#include <time.h>

#include <iostream>

#include "fake_pulse.h"
#include "test_support.h"

namespace {
using Sound = NativeAudio::Sound;
void Idle() {
  Wait([] { return FakeStats().resources == 0; }, "connection retained");
}

void Deadlines() {
  FakeReset();
  auto audio = Initialize();
  Reply expired;
  audio->Play(Sound::kAlarm, Request("expired", 0, 0, -1), expired.callback());
  Check(expired.Get() < 0 && FakeStats().connects == 0,
        "expired receive connected");
  for (int stage = 0; stage < 3; ++stage) {
    PulsePlan delayed;
    if (stage == 0) delayed.connect_delay_ms = 250;
    if (stage == 1) delayed.stream_delay_ms = 250;
    if (stage == 2) delayed.writable_delay_ms = 250;
    FakePlan(delayed);
    Reply late;
    audio->Play(Sound::kAlarm,
                Request("late" + std::to_string(stage), 0, 0, 49),
                late.callback());
    Check(late.Get() < 0 && FakeStats().writes == 0,
          "late native alarm started");
    Check(*late.calls == 1, "late alarm replied twice");
    Idle();
  }
  FakePlan({});
  Reply end;
  audio->Play(Sound::kEnd, {"end", 0, 0, 0}, end.callback());
  const int64_t ended = end.Get();
  Check(ended >= 0, "historical end was dropped");
  Idle();
  Check(FakeStats().pcm.size() == 600, "end must play three copies");
  Reply duplicate_end;
  audio->Play(Sound::kEnd, {"end", 0, 0, 0}, duplicate_end.callback());
  Check(duplicate_end.Get() == ended && FakeStats().pcm.size() == 600,
        "historical end retry replayed completion");
  timespec now{};
  clock_gettime(CLOCK_BOOTTIME, &now);
  const auto expected =
      static_cast<int64_t>(now.tv_sec) * 1000 + now.tv_nsec / 1000000;
  Check(std::abs(expected - NativeAudio::NowMs()) <= 1,
        "native clock differs from boottime");
}

void PlannedGuard() {
  PulsePlan delayed;
  delayed.connect_delay_ms = 50;
  FakeReset(delayed);
  auto audio = Initialize();
  Reply first;
  const int64_t sent = NativeAudio::NowMs();
  audio->Play(Sound::kAlarm, Request("first", 0, 0, 5000, sent),
              first.callback());
  const int64_t started = first.Get();
  Check(started >= sent + 50,
        "delayed connection did not delay successful start");
  Idle();
  FakePlan({});
  Until(sent + 3000);
  Reply valid;
  audio->Play(Sound::kAlarm, Request("next", 0, 0, 5000, sent + 3000),
              valid.callback());
  const int64_t next_started = valid.Get();
  Check(next_started >= sent + 3000 && next_started - started < 3000,
        "50ms timing jitter suppressed a cue planned exactly 3 seconds later");
  Idle();
  Reply too_early;
  audio->Play(Sound::kAlarm, Request("too-close", 0, 0, 5000, sent + 5999),
              too_early.callback());
  Check(too_early.Get() < 0,
        "planned cue spacing below 3000ms passed the guard");
}

void FailedStartAndDuplicates() {
  PulsePlan failed;
  failed.fail_write = true;
  FakeReset(failed);
  auto audio = Initialize();
  Reply failure;
  audio->Play(Sound::kAlarm, Request("same"), failure.callback());
  Check(failure.Get() < 0, "failed write acknowledged success");
  FakePlan({});
  Reply success;
  audio->Play(Sound::kAlarm, Request("same"), success.callback());
  const int64_t started = success.Get();
  Check(started >= 0, "failed write consumed guard or event identity");
  Idle();
  const auto writes = FakeStats().writes;
  std::vector<std::thread> callers;
  std::vector<std::unique_ptr<Reply>> duplicates;
  for (int i = 0; i < 8; ++i) {
    duplicates.push_back(std::make_unique<Reply>());
    auto callback = duplicates.back()->callback();
    callers.emplace_back([&, callback] {
      audio->Play(Sound::kAlarm, Request("same"), callback);
    });
  }
  for (auto& caller : callers) caller.join();
  for (auto& reply : duplicates) {
    Check(reply->Get() == started && *reply->calls == 1,
          "duplicate did not return original start");
  }
  Check(FakeStats().writes == writes, "duplicate event played twice");
  audio->Stop(0, 1, true);
  Reply after_cancel;
  audio->Play(Sound::kAlarm, Request("same", 0, 1), after_cancel.callback());
  Check(after_cancel.Get() == started,
        "alarm cancellation lost successful event identity");
  audio->Stop(1, 2);
  Reply bypass;
  audio->Play(Sound::kAlarm, Request("new", 1, 2), bypass.callback());
  Check(bypass.Get() < 0, "stop bypassed successful planned-cue guard");
}

void CancelStages() {
  for (const auto stage : {Stall::kConnect, Stall::kStream, Stall::kWritable,
                           Stall::kBuffered, Stall::kDrain}) {
    PulsePlan stuck;
    stuck.stall = stage;
    FakeReset(stuck);
    auto audio = Initialize();
    Reply first;
    audio->Play(Sound::kAlarm, Request("first"), first.callback());
    Wait(
        [&] {
          const auto stats = FakeStats();
          if (stage == Stall::kConnect) return stats.connects > 0;
          if (stage == Stall::kStream || stage == Stall::kWritable)
            return stats.streams > 0;
          if (stage == Stall::kBuffered) return stats.writes >= 4;
          return stats.drains > 0;
        },
        "fault injection stage not reached");
    const auto stop_at = NativeAudio::NowMs();
    audio->Stop(1, 1);
    Wait([] { return FakeStats().resources == 0; },
         "stop retained stalled connection", 50);
    Check(NativeAudio::NowMs() - stop_at <= 50, "stop exceeded 50ms");
    const auto result = first.Get();
    Check(
        (result >= 0) == (stage == Stall::kBuffered || stage == Stall::kDrain),
        "start reply did not match first enqueue");
    Check(*first.calls == 1, "cancel replied more than once");
    if (stage == Stall::kDrain)
      Check(FakeStats().cancellations == 1, "drain was not cancelled");
    Reply stale;
    audio->Play(Sound::kEnd, Request("stale", 0, 0), stale.callback());
    Check(stale.Get() < 0, "old generation survived stop");
    FakePlan({});
    Reply next;
    audio->Play(Sound::kEnd, Request("next", 1, 1), next.callback());
    Check(next.Get() >= 0, "stuck server wedged subsequent sound");
    Idle();
  }
}

void AlarmCancellationAndQueue() {
  PulsePlan delayed;
  delayed.stall = Stall::kConnect;
  FakeReset(delayed);
  auto audio = Initialize();
  Reply first, duplicate;
  audio->Play(Sound::kAlarm, Request("alarm"), first.callback());
  Wait([] { return FakeStats().connects > 0; }, "connect not reached");
  audio->Play(Sound::kAlarm, Request("alarm"), duplicate.callback());
  Check(duplicate.Get() < 0, "pending duplicate should retry");
  audio->Stop(0, 1, true);
  Check(first.Get() < 0, "alarm-only cancellation failed");
  Reply stale;
  audio->Play(Sound::kAlarm, Request("stale"), stale.callback());
  Check(stale.Get() < 0, "stale alarm generation played");
  Idle();
  PulsePlan draining;
  draining.stall = Stall::kDrain;
  FakePlan(draining);
  Reply end;
  audio->Play(Sound::kEnd, Request("end", 0, 0), end.callback());
  Check(end.Get() >= 0, "finish incorrectly uses alarm generation");
  Wait([] { return FakeStats().drains > 0; }, "drain not reached");
  audio->Stop(0, 2, true);
  std::this_thread::sleep_for(std::chrono::milliseconds(30));
  Check(FakeStats().resources > 0 && FakeStats().cancellations == 0,
        "cancelAlarm killed finish");
  audio->Stop(2, 3);
  Idle();
  FakePlan(delayed);
  Reply old, middle, latest;
  audio->Play(Sound::kAlarm, Request("old", 2, 3), old.callback());
  Wait([] { return FakeStats().connects >= 3; }, "old connect not reached");
  audio->Play(Sound::kAlarm, Request("middle", 2, 3), middle.callback());
  FakePlan({});
  audio->Play(Sound::kEnd, Request("latest", 2, 3), latest.callback());
  Check(old.Get() < 0 && middle.Get() < 0 && latest.Get() >= 0,
        "queued superseded requests did not finish correctly");
  Idle();
}

void StalledServerTimeoutsAndDispose() {
  for (const auto stage : {Stall::kConnect, Stall::kStream, Stall::kWritable,
                           Stall::kBuffered, Stall::kDrain}) {
    PulsePlan stuck;
    stuck.stall = stage;
    FakeReset(stuck);
    auto audio = Initialize();
    Reply request;
    const auto before = NativeAudio::NowMs();
    audio->Play(Sound::kEnd, Request("end"), request.callback());
    const auto start = request.Get();
    Check((start >= 0) == (stage == Stall::kBuffered || stage == Stall::kDrain),
          "timeout reported wrong start result");
    Idle();
    Check(NativeAudio::NowMs() - before < 1400,
          "server timeout was not bounded");
    FakePlan({});
    Reply next;
    audio->Play(Sound::kEnd, Request("next"), next.callback());
    Check(next.Get() >= 0, "timeout wedged next play");
    Idle();
    audio.reset();

    FakeReset(stuck);
    audio = Initialize();
    Reply disposal;
    audio->Play(Sound::kEnd, Request("dispose"), disposal.callback());
    Wait(
        [&] {
          const auto stats = FakeStats();
          if (stage == Stall::kConnect) return stats.connects > 0;
          if (stage == Stall::kStream || stage == Stall::kWritable)
            return stats.streams > 0;
          if (stage == Stall::kBuffered) return stats.writes >= 4;
          return stats.drains > 0;
        },
        "dispose stage not reached");
    const auto disposing = NativeAudio::NowMs();
    audio.reset();
    Check(NativeAudio::NowMs() - disposing <= 50, "dispose blocked on server");
    disposal.Get();
    Check(*disposal.calls == 1 && FakeStats().resources == 0,
          "dispose leaked callbacks or audio resources");
  }
  PulsePlan stuck;
  stuck.stall = Stall::kConnect;
  FakeReset(stuck);
  auto audio = Initialize();
  Reply current, queued;
  audio->Play(Sound::kEnd, Request("current"), current.callback());
  Wait([] { return FakeStats().connects > 0; },
       "queued disposal did not connect");
  audio->Play(Sound::kEnd, Request("queued"), queued.callback());
  audio.reset();
  Check(current.Get() < 0 && queued.Get() < 0 && *current.calls == 1 &&
            *queued.calls == 1 && FakeStats().resources == 0,
        "dispose lost an in-flight or queued reply");
}

void BeginWorkoutPreservesOnlyPlayingEnd() {
  PulsePlan draining;
  draining.stall = Stall::kDrain;
  FakeReset(draining);
  auto audio = Initialize();
  Reply current, queued;
  auto release = std::make_shared<std::promise<void>>();
  auto gate = release->get_future().share();
  auto report = current.callback();
  audio->Play(Sound::kEnd, Request("end"), [report, gate](int64_t at) {
    report(at);
    gate.wait_for(std::chrono::seconds(2));
  });
  Check(current.Get() >= 0, "end did not start before new workout");
  audio->Play(Sound::kEnd, Request("old-queued"), queued.callback());
  audio->BeginWorkout(1, 1);
  Check(queued.Get() < 0 && *queued.calls == 1,
        "new workout failed to cancel queued old completion");
  release->set_value();
  Wait([] { return FakeStats().drains == 1; },
       "preserved end did not continue");
  std::this_thread::sleep_for(std::chrono::milliseconds(30));
  Check(FakeStats().disconnects == 0 && FakeStats().cancellations == 0,
        "new workout cut off an already playing end");
  Reply stale_end, stale_alarm;
  audio->Play(Sound::kEnd, Request("end", 0, 0), stale_end.callback());
  audio->Play(Sound::kAlarm, Request("old-alarm", 0, 0),
              stale_alarm.callback());
  Check(stale_end.Get() < 0 && stale_alarm.Get() < 0,
        "new workout accepted an older event generation");
  audio->BeginWorkout(0, 0);
  Check(FakeStats().disconnects == 0,
        "stale beginWorkout cancelled current end");
  FakePlan({});
  Reply next_alarm;
  audio->Play(Sound::kAlarm, Request("new-alarm", 1, 1), next_alarm.callback());
  Check(next_alarm.Get() >= 0, "new cue could not replace preserved end");
  Idle();
  Check(FakeStats().cancellations == 1,
        "replacement did not interrupt old end drain");

  FakePlan(draining);
  Reply new_end;
  audio->Play(Sound::kEnd, Request("end", 1, 1), new_end.callback());
  Check(new_end.Get() >= 0,
        "new workout retained an old successful event ledger");
  Wait([] { return FakeStats().drains == 3; }, "new end did not drain");
  audio->BeginWorkout(2, 2);
  audio->Stop(3, 3);
  Wait([] { return FakeStats().resources == 0; },
       "stop did not silence preserved end", 50);
  Check(FakeStats().cancellations == 2,
        "full stop left preserved end draining");

  PulsePlan connecting;
  connecting.stall = Stall::kConnect;
  FakePlan(connecting);
  Reply pending;
  const auto connections = FakeStats().connects;
  audio->Play(Sound::kEnd, Request("pending", 3, 3), pending.callback());
  Wait([&] { return FakeStats().connects > connections; },
       "pending end did not connect");
  audio->BeginWorkout(4, 4);
  Check(pending.Get() < 0, "new workout allowed an old end to start late");
  Idle();
  audio->BeginWorkout(5, 3);
  FakePlan({});
  Reply current_generation;
  audio->Play(Sound::kEnd, Request("current-generation", 4, 4),
              current_generation.callback());
  Check(current_generation.Get() >= 0,
        "stale alarm generation in beginWorkout advanced the full generation");
  Idle();
}

void AssetsAndGain() {
  FakeReset();
  auto audio = Initialize(true);
  audio->SetVolume(0.25);
  Reply end;
  audio->Play(Sound::kEnd, Request("end"), end.callback());
  Check(end.Get() >= 0, "bundled end failed");
  Idle();
  Check(FakeStats().pcm.size() == 51841 * 2 * 2 * 3,
        "bundled end repeat byte count differs");
  audio.reset();
  FakeReset();
  audio = Initialize();
  audio->SetVolume(0.25);
  Reply tone;
  audio->Play(Sound::kEnd, Request("tone"), tone.callback());
  Check(tone.Get() >= 0, "gain probe failed");
  Idle();
  const auto pcm = FakeStats().pcm;
  for (size_t i = 0; i < pcm.size(); i += 2)
    Check((pcm[i] | (pcm[i + 1] << 8)) == 2500, "gain not applied to PCM");
}
}

int main() {
  try {
    for (const auto& test : std::vector<std::pair<const char*, void (*)()>>{
             {"deadlines and boottime", Deadlines},
             {"planned 3000ms guard with actual receipt", PlannedGuard},
             {"failed starts and concurrent duplicates",
              FailedStartAndDuplicates},
             {"stop at every server stage", CancelStages},
             {"alarm-only cancellation and queued requests",
              AlarmCancellationAndQueue},
             {"stuck server timeouts and disposal",
              StalledServerTimeoutsAndDispose},
             {"beginWorkout preserves playing end only",
              BeginWorkoutPreservesOnlyPlayingEnd},
             {"bundled WAVs, end repeats and gain", AssetsAndGain}}) {
      test.second();
      std::cout << "PASS " << test.first << '\n';
    }
  } catch (const std::exception& error) {
    std::cerr << "FAIL " << error.what() << '\n';
    return 1;
  }
}
