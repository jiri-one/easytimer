#include "platform_bridge.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <system_error>
#include <utility>

#include "native_audio.h"
#include "native_protocol.h"

namespace {

void RespondBool(FlMethodCall* call, bool value) {
  g_autoptr(FlValue) result = fl_value_new_bool(value);
  fl_method_call_respond_success(call, result, nullptr);
}

struct Reply {
  FlMethodCall* call;
  std::shared_ptr<std::atomic<bool>> alive;
  bool success = false;
  bool playback = false;
  int64_t started_at_ms = -1;

  ~Reply() { g_object_unref(call); }
};

class PlatformBridge {
 public:
  PlatformBridge(GtkApplication* application, GtkWindow* window)
      : application_(application), window_(window) {}

  ~PlatformBridge() {
    *alive_ = false;
    KeepAwake(false);
  }

  void Handle(FlMethodCall* call) {
    const char* method = fl_method_call_get_name(call);
    FlValue* args = fl_method_call_get_args(call);
    if (std::strcmp(method, "initialize") == 0) {
      std::vector<uint8_t> alarm;
      std::vector<uint8_t> end;
      if (!ReadBytes(args, "alarm", &alarm) || !ReadBytes(args, "end", &end)) {
        audio_.reset();
        RespondBool(call, false);
        return;
      }
      if (!audio_) {
        try {
          audio_ = std::make_unique<NativeAudio>();
        } catch (const std::system_error&) {
          RespondBool(call, false);
          return;
        }
      }
      audio_->SetVolume(gain_);
      audio_->Initialize(std::move(alarm), std::move(end), Complete(call));
      return;
    }
    if (std::strcmp(method, "playAlarm") == 0 ||
        std::strcmp(method, "playEnd") == 0) {
      NativeAudio::Request request;
      if (!native_protocol::ReadRequest(args, &request)) {
        Invalid(call,
                "Expected an event ID, generations, planned time and native "
                "deadline");
        return;
      }
      if (audio_) {
        audio_->Play(std::strcmp(method, "playAlarm") == 0
                         ? NativeAudio::Sound::kAlarm
                         : NativeAudio::Sound::kEnd,
                     std::move(request), PlaybackComplete(call));
      } else {
        fl_method_call_respond_success(call, nullptr, nullptr);
      }
      return;
    }
    if (std::strcmp(method, "cancelAlarm") == 0 ||
        std::strcmp(method, "stop") == 0 ||
        std::strcmp(method, "beginWorkout") == 0) {
      int64_t generation;
      int64_t alarm_generation;
      if (!native_protocol::ReadInt(args, "generation", &generation) ||
          !native_protocol::ReadInt(args, "alarmGeneration",
                                    &alarm_generation)) {
        Invalid(call, "Expected nonnegative generations");
        return;
      }
      if (audio_) {
        if (std::strcmp(method, "beginWorkout") == 0)
          audio_->BeginWorkout(generation, alarm_generation);
        else
          audio_->Stop(generation, alarm_generation,
                       std::strcmp(method, "cancelAlarm") == 0);
      }
    } else if (std::strcmp(method, "setVolume") == 0) {
      double gain;
      if (args && fl_value_get_type(args) == FL_VALUE_TYPE_FLOAT) {
        gain = fl_value_get_float(args);
      } else if (args && fl_value_get_type(args) == FL_VALUE_TYPE_INT) {
        gain = static_cast<double>(fl_value_get_int(args));
      } else {
        Invalid(call, "Expected a finite volume gain");
        return;
      }
      if (!std::isfinite(gain)) {
        Invalid(call, "Expected a finite volume gain");
        return;
      }
      gain_ = std::max(0.0, std::min(1.0, gain));
      if (audio_) audio_->SetVolume(gain_);
    } else if (std::strcmp(method, "keepAwake") == 0) {
      if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_BOOL) {
        Invalid(call, "Expected a boolean");
        return;
      }
      KeepAwake(fl_value_get_bool(args));
    } else if (std::strcmp(method, "dispose") == 0) {
      audio_.reset();
      KeepAwake(false);
    } else {
      fl_method_call_respond_not_implemented(call, nullptr);
      return;
    }
    fl_method_call_respond_success(call, nullptr, nullptr);
  }

 private:
  std::shared_ptr<Reply> NewReply(FlMethodCall* call) {
    auto reply = std::make_shared<Reply>();
    reply->call = FL_METHOD_CALL(g_object_ref(call));
    reply->alive = alive_;
    return reply;
  }

  static void PostReply(std::shared_ptr<Reply> reply) {
    // Flutter replies belong to GTK's thread and must not outlive the view.
    g_idle_add_full(
        G_PRIORITY_DEFAULT,
        [](gpointer data) -> gboolean {
          const auto& result = *static_cast<std::shared_ptr<Reply>*>(data);
          if (*result->alive) {
            if (!result->playback) {
              RespondBool(result->call, result->success);
            } else {
              g_autoptr(FlValue) value =
                  native_protocol::PlaybackResult(result->started_at_ms);
              fl_method_call_respond_success(result->call, value, nullptr);
            }
          }
          return G_SOURCE_REMOVE;
        },
        new std::shared_ptr<Reply>(std::move(reply)),
        [](gpointer data) {
          delete static_cast<std::shared_ptr<Reply>*>(data);
        });
  }

  NativeAudio::Completion Complete(FlMethodCall* call) {
    return [reply = NewReply(call)](bool success) mutable {
      reply->success = success;
      PostReply(std::move(reply));
    };
  }

  NativeAudio::PlaybackCompletion PlaybackComplete(FlMethodCall* call) {
    return [reply = NewReply(call)](int64_t started_at_ms) mutable {
      reply->playback = true;
      reply->started_at_ms = started_at_ms;
      PostReply(std::move(reply));
    };
  }

  static bool ReadBytes(FlValue* args, const char* key,
                        std::vector<uint8_t>* bytes) {
    if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return false;
    FlValue* value = fl_value_lookup_string(args, key);
    if (!value || fl_value_get_type(value) != FL_VALUE_TYPE_UINT8_LIST)
      return false;
    const auto size = fl_value_get_length(value);
    if (size == 0 || size > 16 * 1024 * 1024) return false;
    const auto* data = fl_value_get_uint8_list(value);
    bytes->assign(data, data + size);
    return true;
  }

  static void Invalid(FlMethodCall* call, const char* message) {
    fl_method_call_respond_error(call, "invalid_arguments", message, nullptr,
                                 nullptr);
  }

  void KeepAwake(bool enabled) {
    if (enabled && inhibit_cookie_ == 0) {
      inhibit_cookie_ = gtk_application_inhibit(
          application_, window_, GTK_APPLICATION_INHIBIT_IDLE, "Timer is running");
    } else if (!enabled && inhibit_cookie_ != 0) {
      gtk_application_uninhibit(application_, inhibit_cookie_);
      inhibit_cookie_ = 0;
    }
  }

  GtkApplication* application_;
  GtkWindow* window_;
  guint inhibit_cookie_ = 0;
  double gain_ = 1.0;
  std::shared_ptr<std::atomic<bool>> alive_ =
      std::make_shared<std::atomic<bool>>(true);
  std::unique_ptr<NativeAudio> audio_;
};

}

void easytimer_platform_attach(FlView* view, GtkApplication* application,
                               GtkWindow* window) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "easytimer/platform", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel,
      [](FlMethodChannel*, FlMethodCall* call, gpointer data) {
        static_cast<PlatformBridge*>(data)->Handle(call);
      },
      new PlatformBridge(application, window),
      [](gpointer data) { delete static_cast<PlatformBridge*>(data); });
  g_signal_connect_data(
      window, "destroy", G_CALLBACK(+[](GtkWidget*, gpointer data) {
        fl_method_channel_set_method_call_handler(FL_METHOD_CHANNEL(data),
                                                  nullptr, nullptr, nullptr);
      }),
      channel, [](gpointer data, GClosure*) { g_object_unref(data); },
      static_cast<GConnectFlags>(0));
}
