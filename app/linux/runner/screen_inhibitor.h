#ifndef EASYTIMER_SCREEN_INHIBITOR_H_
#define EASYTIMER_SCREEN_INHIBITOR_H_

#include <glib.h>

#include <functional>
#include <memory>
#include <string>

// Keep all access on the GTK/main-loop thread to protect the callbacks' GTK
// captures, and keep its context running so late cookies can be released.
class ScreenInhibitor {
 public:
  using GtkAcquire = std::function<guint()>;
  using GtkRelease = std::function<void(guint)>;
  using FlatpakDetector = std::function<bool()>;

  ScreenInhibitor(GtkAcquire gtk_acquire, GtkRelease gtk_release,
                  std::string application_name = "EasyTimer",
                  std::string reason = "Timer is running",
                  FlatpakDetector in_flatpak = {});
  ~ScreenInhibitor();
  ScreenInhibitor(const ScreenInhibitor&) = delete;
  ScreenInhibitor& operator=(const ScreenInhibitor&) = delete;

  void SetEnabled(bool enabled);

  void Dispose();

 private:
  struct State;
  std::shared_ptr<State> state_;
};

#endif
