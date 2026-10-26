#ifndef EASYTIMER_NATIVE_PROTOCOL_H_
#define EASYTIMER_NATIVE_PROTOCOL_H_

#include <flutter_linux/flutter_linux.h>

#include <cstring>

#include "native_audio.h"

namespace native_protocol {
inline bool ReadInt(FlValue* args, const char* key, int64_t* number) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return false;
  FlValue* value = fl_value_lookup_string(args, key);
  if (!value || fl_value_get_type(value) != FL_VALUE_TYPE_INT) return false;
  *number = fl_value_get_int(value);
  return *number >= 0;
}

inline bool ReadRequest(FlValue* args, NativeAudio::Request* request) {
  if (!ReadInt(args, "generation", &request->generation) ||
      !ReadInt(args, "alarmGeneration", &request->alarm_generation) ||
      !ReadInt(args, "deadlineMs", &request->deadline_ms) ||
      !ReadInt(args, "plannedAtMs", &request->planned_at_ms))
    return false;
  FlValue* id = fl_value_lookup_string(args, "eventId");
  if (!id || fl_value_get_type(id) != FL_VALUE_TYPE_STRING) return false;
  const char* text = fl_value_get_string(id);
  const size_t size = strnlen(text, 1025);
  if (size == 0 || size > 1024) return false;
  request->event_id.assign(text, size);
  return true;
}

inline FlValue* PlaybackResult(int64_t started_at_ms) {
  if (started_at_ms < 0) return nullptr;
  FlValue* value = fl_value_new_map();
  fl_value_set_string_take(value, "startedAtMs",
                           fl_value_new_int(started_at_ms));
  return value;
}
}
#endif
