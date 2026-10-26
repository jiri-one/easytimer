#include "native_protocol.h"

#include <iostream>
#include <stdexcept>

namespace {
void Check(bool valid, const char* why) {
  if (!valid) throw std::runtime_error(why);
}
FlValue* Request(bool include_planned = true) {
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "eventId", fl_value_new_string("alarm:42"));
  fl_value_set_string_take(map, "generation", fl_value_new_int(1));
  fl_value_set_string_take(map, "alarmGeneration", fl_value_new_int(2));
  fl_value_set_string_take(map, "deadlineMs", fl_value_new_int(INT64_MAX));
  if (include_planned)
    fl_value_set_string_take(map, "plannedAtMs",
                             fl_value_new_int(INT64_MAX - 1));
  return map;
}
}

int main() {
  try {
    NativeAudio::Request parsed;
    Check(!native_protocol::ReadRequest(nullptr, &parsed),
          "null args accepted");
    g_autoptr(FlValue) scalar = fl_value_new_int(1);
    Check(!native_protocol::ReadRequest(scalar, &parsed),
          "scalar args accepted");
    g_autoptr(FlValue) missing_planned = Request(false);
    Check(!native_protocol::ReadRequest(missing_planned, &parsed),
          "missing planned cue timestamp accepted");
    g_autoptr(FlValue) valid = Request();
    Check(native_protocol::ReadRequest(valid, &parsed) &&
              parsed.event_id == "alarm:42" && parsed.generation == 1 &&
              parsed.alarm_generation == 2 && parsed.deadline_ms == INT64_MAX &&
              parsed.planned_at_ms == INT64_MAX - 1,
          "valid protocol request rejected or narrowed");
    for (const auto* field :
         {"generation", "alarmGeneration", "deadlineMs", "plannedAtMs"}) {
      for (auto* invalid : {fl_value_new_null(), fl_value_new_float(1),
                            fl_value_new_string("1"), fl_value_new_bool(true),
                            fl_value_new_int(-1), fl_value_new_list()}) {
        g_autoptr(FlValue) args = Request();
        fl_value_set_string_take(args, field, invalid);
        Check(!native_protocol::ReadRequest(args, &parsed),
              "malformed integer accepted");
      }
    }
    for (auto* invalid :
         {fl_value_new_null(), fl_value_new_int(1), fl_value_new_string(""),
          fl_value_new_string(std::string(1025, 'x').c_str())}) {
      g_autoptr(FlValue) args = Request();
      fl_value_set_string_take(args, "eventId", invalid);
      Check(!native_protocol::ReadRequest(args, &parsed),
            "malformed event ID accepted");
    }
    Check(native_protocol::PlaybackResult(-1) == nullptr,
          "failure must be null");
    g_autoptr(FlValue) result = native_protocol::PlaybackResult(INT64_MAX);
    Check(fl_value_get_type(result) == FL_VALUE_TYPE_MAP &&
              fl_value_get_length(result) == 1 &&
              fl_value_get_int(fl_value_lookup_string(result, "startedAtMs")) ==
                  INT64_MAX,
          "successful reply map differs from protocol");
    std::cout << "PASS native MethodChannel argument parsing and reply maps\n";
  } catch (const std::exception& error) {
    std::cerr << "FAIL " << error.what() << '\n';
    return 1;
  }
}
