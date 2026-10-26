#include "screen_inhibitor.h"

#include <gio/gio.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

constexpr char kService[] = "org.freedesktop.ScreenSaver";
constexpr char kPath[] = "/org/freedesktop/ScreenSaver";
constexpr char kMarker[] = "EASYTIMER_INHIBIT_PRIVATE_BUS";
using Clock = std::chrono::steady_clock;
GMainContext* test_context = nullptr;

void Check(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void Pump() {
  while (g_main_context_iteration(test_context, FALSE)) {}
}

template <typename Predicate>
void Wait(Predicate predicate, const char* message, int timeout_ms = 2500) {
  const auto until = Clock::now() + std::chrono::milliseconds(timeout_ms);
  while (!predicate()) {
    Check(Clock::now() < until, message);
    Pump();
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  Pump();
}

void Spin(int milliseconds = 30) {
  const auto until = Clock::now() + std::chrono::milliseconds(milliseconds);
  while (Clock::now() < until) {
    Pump();
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
}

template <typename Action>
void Prompt(Action action) {
  const auto start = Clock::now();
  action();
  Check(Clock::now() - start < std::chrono::milliseconds(50),
        "inhibit control/destruction blocked for 50 ms");
}

enum class Mode { kSuccess, kHold, kError, kMalformed };

struct Request {
  std::string sender;
  std::string application;
  std::string reason;
  guint cookie;
  GDBusMethodInvocation* pending;
};

class ScreenSaver {
 public:
  ScreenSaver() {
    GError* error = nullptr;
    connection_ = g_dbus_connection_new_for_address_sync(
        g_getenv("DBUS_SESSION_BUS_ADDRESS"),
        static_cast<GDBusConnectionFlags>(
            G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
            G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
        nullptr, nullptr, &error);
    if (!connection_) {
      const std::string message = error ? error->message : "no mock connection";
      g_clear_error(&error);
      throw std::runtime_error(message);
    }
    g_dbus_connection_set_exit_on_close(connection_, FALSE);
    g_autoptr(GDBusNodeInfo) info = g_dbus_node_info_new_for_xml(
        "<node><interface name='org.freedesktop.ScreenSaver'>"
        "<method name='Inhibit'><arg type='s' direction='in'/>"
        "<arg type='s' direction='in'/><arg type='u' direction='out'/></method>"
        "<method name='UnInhibit'><arg type='u' direction='in'/></method>"
        "</interface></node>",
        nullptr);
    const GDBusInterfaceVTable methods = {Call, nullptr, nullptr, {nullptr}};
    object_id_ = g_dbus_connection_register_object(
        connection_, kPath, info->interfaces[0], &methods, this, nullptr, nullptr);
    Check(object_id_ != 0, "could not register mock ScreenSaver");
    signal_id_ = g_dbus_connection_signal_subscribe(
        connection_, "org.freedesktop.DBus", "org.freedesktop.DBus",
        "NameOwnerChanged", "/org/freedesktop/DBus", nullptr,
        G_DBUS_SIGNAL_FLAGS_NONE,
        [](GDBusConnection*, const gchar*, const gchar*, const gchar*,
           const gchar*, GVariant* parameters, gpointer data) {
          auto& self = *static_cast<ScreenSaver*>(data);
          const gchar* name;
          const gchar* before;
          const gchar* after;
          g_variant_get(parameters, "(&s&s&s)", &name, &before, &after);
          if (name[0] != ':') return;
          if (!*before && *after) {
            self.peers.insert(name);
            ++self.opened;
          } else if (*before && !*after) {
            self.peers.erase(name);
            self.disconnected.insert(name);
            // Real screensavers scope inhibitors to the caller's bus lifetime;
            // this catches cookies lost to timeout or malformed/error replies.
            for (auto it = self.cookies.begin(); it != self.cookies.end();) {
              if (it->second == name) {
                ++self.disconnect_cleanup;
                it = self.cookies.erase(it);
              } else {
                ++it;
              }
            }
          }
        },
        this, nullptr);
    // This round trip also orders AddMatch before clients start connecting.
    OwnName();
  }

  ~ScreenSaver() {
    for (auto& request : inhibits)
      if (request.pending) g_object_unref(request.pending);
    for (auto& request : releases)
      if (request.pending) g_object_unref(request.pending);
    if (owns_name_) DropName();
    g_dbus_connection_signal_unsubscribe(connection_, signal_id_);
    g_dbus_connection_unregister_object(connection_, object_id_);
    g_dbus_connection_close_sync(connection_, nullptr, nullptr);
    g_object_unref(connection_);
    Pump();
  }

  void OwnName() {
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
        connection_, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "RequestName", g_variant_new("(su)", kService, 4),
        G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
    guint result = 0;
    if (reply) g_variant_get(reply, "(u)", &result);
    Check(result == 1, "private mock could not own ScreenSaver name");
    owns_name_ = true;
  }

  void DropName() {
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
        connection_, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "ReleaseName", g_variant_new("(s)", kService),
        G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
    owns_name_ = false;
  }

  void AnswerInhibit(size_t index, Mode mode = Mode::kSuccess) {
    auto& request = inhibits.at(index);
    Check(request.pending != nullptr, "Inhibit answered twice");
    Answer(request, mode, false);
  }

  void AnswerRelease(size_t index) {
    auto& request = releases.at(index);
    Check(request.pending != nullptr, "UnInhibit answered twice");
    Answer(request, Mode::kSuccess, true);
  }

  void Clean() {
    Wait([&] { return cookies.empty() && peers.empty(); },
         "fallback leaked a cookie or private bus connection");
    Check(bad_release == 0, "UnInhibit used a wrong cookie or sender");
  }

  Mode inhibit_mode = Mode::kSuccess;
  Mode release_mode = Mode::kSuccess;
  guint next_cookie = 41;
  int opened = 0;
  int disconnect_cleanup = 0;
  int bad_release = 0;
  std::vector<Request> inhibits;
  std::vector<Request> releases;
  std::map<guint, std::string> cookies;
  std::set<std::string> peers;
  std::set<std::string> disconnected;

 private:
  static void Call(GDBusConnection*, const gchar* sender, const gchar*,
                   const gchar*, const gchar* method, GVariant* parameters,
                   GDBusMethodInvocation* invocation, gpointer data) {
    auto& self = *static_cast<ScreenSaver*>(data);
    if (std::strcmp(method, "Inhibit") == 0) {
      const gchar* application;
      const gchar* reason;
      g_variant_get(parameters, "(&s&s)", &application, &reason);
      const guint cookie = self.next_cookie++;
      self.cookies.emplace(cookie, sender);
      self.inhibits.push_back({sender, application, reason, cookie, invocation});
      self.Answer(self.inhibits.back(), self.inhibit_mode, false);
    } else {
      guint cookie;
      g_variant_get(parameters, "(u)", &cookie);
      const auto found = self.cookies.find(cookie);
      if (found == self.cookies.end() || found->second != sender)
        ++self.bad_release;
      self.releases.push_back({sender, "", "", cookie, invocation});
      self.Answer(self.releases.back(), self.release_mode, true);
    }
  }

  void Answer(Request& request, Mode mode, bool release) {
    if (mode == Mode::kHold) return;
    GDBusMethodInvocation* invocation = request.pending;
    request.pending = nullptr;
    if (mode == Mode::kError) {
      g_dbus_method_invocation_return_dbus_error(
          invocation, "org.freedesktop.ScreenSaver.TestFailure", "test failure");
    } else if (mode == Mode::kMalformed) {
      // A raw reply avoids GDBus' server-side signature validation, allowing the
      // production client's validation and sender cleanup to be exercised.
      g_autoptr(GDBusMessage) reply = g_dbus_message_new_method_reply(
          g_dbus_method_invocation_get_message(invocation));
      g_dbus_message_set_body(reply, g_variant_new("(s)", "not a uint cookie"));
      g_dbus_connection_send_message(connection_, reply,
                                     G_DBUS_SEND_MESSAGE_FLAGS_NONE, nullptr,
                                     nullptr);
      g_object_unref(invocation);
    } else {
      if (release) cookies.erase(request.cookie);
      g_dbus_method_invocation_return_value(
          invocation, release ? g_variant_new("()")
                              : g_variant_new("(u)", request.cookie));
    }
  }

  GDBusConnection* connection_ = nullptr;
  guint object_id_ = 0;
  guint signal_id_ = 0;
  bool owns_name_ = false;
};

struct GtkProbe {
  const std::thread::id owner = std::this_thread::get_id();
  guint cookie = 0;
  int acquires = 0;
  std::vector<guint> releases;

  std::unique_ptr<ScreenInhibitor> Create(
      ScreenInhibitor::FlatpakDetector flatpak = [] { return false; }) {
    return std::make_unique<ScreenInhibitor>(
        [this] {
          Check(std::this_thread::get_id() == owner, "GTK acquired off-thread");
          ++acquires;
          return cookie;
        },
        [this](guint value) {
          Check(std::this_thread::get_id() == owner, "GTK released off-thread");
          releases.push_back(value);
        },
        "Test timer", "Workout in progress", std::move(flatpak));
  }
};

void GtkSuccess() {
  ScreenSaver service;
  GtkProbe gtk;
  gtk.cookie = 17;
  auto inhibitor = gtk.Create([]() -> bool {
    throw std::runtime_error("Flatpak checked despite GTK success");
  });
  inhibitor->SetEnabled(true);
  inhibitor->SetEnabled(true);
  Spin();
  Check(gtk.acquires == 1 && service.inhibits.empty() && service.opened == 0,
        "GTK success started fallback or acquired twice");
  inhibitor->SetEnabled(false);
  inhibitor->SetEnabled(false);
  Check(gtk.releases == std::vector<guint>{17}, "GTK cookie not released once");
  inhibitor->SetEnabled(true);
  Prompt([&] { inhibitor.reset(); });
  Check(gtk.acquires == 2 && gtk.releases == std::vector<guint>({17, 17}),
        "GTK reacquire/destructor cleanup failed");
  service.Clean();
}

void FallbackSuccess() {
  ScreenSaver service;
  GtkProbe gtk;
  auto inhibitor = gtk.Create();
  Prompt([&] { inhibitor->SetEnabled(true); });
  inhibitor->SetEnabled(true);
  Wait([&] { return service.inhibits.size() == 1; }, "fallback not requested");
  Spin();
  inhibitor->SetEnabled(true);
  Check(gtk.acquires == 1 && service.inhibits.size() == 1,
        "pending/held fallback was not idempotent");
  Check(service.inhibits[0].application == "Test timer" &&
            service.inhibits[0].reason == "Workout in progress",
        "Inhibit application/reason changed");
  Prompt([&] { inhibitor->SetEnabled(false); });
  service.Clean();
  Check(service.releases.size() == 1 && gtk.releases.empty(),
        "fallback did not release via UnInhibit");
  inhibitor->SetEnabled(true);
  Wait([&] { return service.inhibits.size() == 2; }, "fallback did not reenable");
  Prompt([&] { inhibitor.reset(); });
  service.Clean();
  Check(service.releases.size() == 2 && service.disconnect_cleanup == 0,
        "successful disposal failed to explicitly release its cookie");
  Check(service.inhibits[0].sender != service.inhibits[1].sender,
        "fallback attempts shared a connection");
}

void FlatpakSuppression(bool use_default_detector = false) {
  ScreenSaver service;
  GtkProbe gtk;
  auto inhibitor = use_default_detector
                       ? gtk.Create({})
                       : gtk.Create([] { return true; });
  inhibitor->SetEnabled(true);
  Spin();
  Check(gtk.acquires == 1 && service.inhibits.empty() && service.opened == 0,
        "Flatpak suppression skipped GTK or opened a fallback connection");
  inhibitor->SetEnabled(false);
  gtk.cookie = 29;
  inhibitor->SetEnabled(true);
  inhibitor->Dispose();
  Check(gtk.acquires == 2 && gtk.releases == std::vector<guint>{29},
        "Flatpak suppression disabled successful GTK inhibition");
  service.Clean();
}

void LateReply(bool dispose, bool destruct) {
  ScreenSaver service;
  service.inhibit_mode = Mode::kHold;
  GtkProbe gtk;
  auto inhibitor = gtk.Create();
  inhibitor->SetEnabled(true);
  Wait([&] { return service.inhibits.size() == 1; }, "Inhibit not pending");
  Prompt([&] {
    if (destruct) inhibitor.reset();
    else if (dispose) inhibitor->Dispose();
    else inhibitor->SetEnabled(false);
  });
  if (dispose && inhibitor) {
    inhibitor->Dispose();
    inhibitor->SetEnabled(true);
    Check(gtk.acquires == 1, "Dispose was not terminal");
  }
  Check(service.releases.empty(), "released a cookie before receiving it");
  service.AnswerInhibit(0);
  service.Clean();
  Check(service.releases.size() == 1 && service.disconnect_cleanup == 0,
        "late cookie was not explicitly released");
}

void GtkCapturesExpire() {
  ScreenSaver service;
  service.inhibit_mode = Mode::kHold;
  auto lifetime = std::make_shared<int>(0);
  std::weak_ptr<int> weak = lifetime;
  auto inhibitor = std::make_unique<ScreenInhibitor>(
      [lifetime]() -> guint { return 0; }, [lifetime](guint) {},
      "Test timer", "Workout in progress", [] { return false; });
  lifetime.reset();
  inhibitor->SetEnabled(true);
  Wait([&] { return service.inhibits.size() == 1; }, "Inhibit not pending");
  inhibitor->Dispose();
  Check(weak.expired(), "asynchronous cleanup retained GTK captures");
  inhibitor.reset();
  service.AnswerInhibit(0);
  service.Clean();
}

void RapidToggle(bool fail_old) {
  ScreenSaver service;
  service.inhibit_mode = Mode::kHold;
  GtkProbe gtk;
  auto inhibitor = gtk.Create();
  inhibitor->SetEnabled(true);
  Wait([&] { return service.inhibits.size() == 1; }, "first Inhibit not pending");
  inhibitor->SetEnabled(false);
  inhibitor->SetEnabled(true);
  Wait([&] { return service.inhibits.size() == 2; }, "reenable stranded inhibit");
  service.AnswerInhibit(1);
  Spin();
  service.AnswerInhibit(0, fail_old ? Mode::kError : Mode::kSuccess);
  Wait([&] { return service.cookies.size() == 1 && service.peers.size() == 1; },
       "stale attempt failed to release independently");
  Check(service.cookies.count(service.inhibits[1].cookie) == 1,
        "old callback released the current inhibit");
  inhibitor->SetEnabled(true);
  Check(gtk.acquires == 2, "old callback cleared the current attempt");
  inhibitor->SetEnabled(false);
  service.Clean();
  Check(service.releases.size() == (fail_old ? 1U : 2U),
        "wrong number of releases after rapid toggle");
}

void RapidToggleDuringConnect() {
  ScreenSaver service;
  GtkProbe gtk;
  auto inhibitor = gtk.Create();
  for (int i = 0; i < 20; ++i) {
    inhibitor->SetEnabled(true);
    inhibitor->SetEnabled(false);
  }
  inhibitor->SetEnabled(true);
  Wait([&] { return service.inhibits.size() == 1 && service.peers.size() == 1; },
       "connection cancellation stranded the final enable");
  Check(gtk.acquires == 21, "rapid toggles did not retry GTK first");
  inhibitor->SetEnabled(false);
  service.Clean();
  Check(service.releases.size() == 1, "cancelled setup sent Inhibit");
}

void ToggleDuringRelease() {
  ScreenSaver service;
  service.release_mode = Mode::kHold;
  GtkProbe gtk;
  auto inhibitor = gtk.Create();
  inhibitor->SetEnabled(true);
  Wait([&] { return service.inhibits.size() == 1; }, "first Inhibit absent");
  inhibitor->SetEnabled(false);
  Wait([&] { return service.releases.size() == 1; }, "release not pending");
  inhibitor->SetEnabled(true);
  Wait([&] { return service.inhibits.size() == 2; }, "enable blocked on release");
  service.AnswerRelease(0);
  Wait([&] { return service.cookies.size() == 1 && service.peers.size() == 1; },
       "old release stranded current inhibit");
  Check(service.cookies.count(service.inhibits[1].cookie) == 1,
        "old release removed new cookie");
  inhibitor.reset();
  Wait([&] { return service.releases.size() == 2; }, "second release absent");
  service.AnswerRelease(1);
  service.Clean();
}

void GtkSucceedsOnReenable() {
  ScreenSaver service;
  service.inhibit_mode = Mode::kHold;
  GtkProbe gtk;
  auto inhibitor = gtk.Create();
  inhibitor->SetEnabled(true);
  Wait([&] { return service.inhibits.size() == 1; }, "Inhibit not pending");
  inhibitor->SetEnabled(false);
  gtk.cookie = 55;
  inhibitor->SetEnabled(true);
  service.AnswerInhibit(0);
  service.Clean();
  Check(service.inhibits.size() == 1 && gtk.releases.empty(),
        "stale fallback touched the newly acquired GTK inhibit");
  inhibitor.reset();
  Check(gtk.releases == std::vector<guint>{55}, "new GTK cookie leaked");
}

void InhibitFailure(Mode mode) {
  ScreenSaver service;
  service.inhibit_mode = mode;
  GtkProbe gtk;
  auto inhibitor = gtk.Create();
  inhibitor->SetEnabled(true);
  Wait([&] { return service.inhibits.size() == 1; }, "failing Inhibit absent");
  service.Clean();
  Check(service.releases.empty() && service.disconnect_cleanup == 1,
        "failed Inhibit leaked its private connection");
  service.inhibit_mode = Mode::kSuccess;
  inhibitor->SetEnabled(true);
  Wait([&] { return service.inhibits.size() == 2; }, "failed Inhibit not retried");
  Check(gtk.acquires == 2, "retry did not start with GTK");
  inhibitor.reset();
  service.Clean();
  Check(service.releases.size() == 1, "retry's cookie not released");
}

void InhibitTimeout() {
  ScreenSaver service;
  service.inhibit_mode = Mode::kHold;
  GtkProbe gtk;
  auto inhibitor = gtk.Create();
  inhibitor->SetEnabled(true);
  Wait([&] { return service.inhibits.size() == 1; }, "Inhibit not pending");
  service.Clean();
  Check(service.disconnect_cleanup == 1 && service.releases.empty(),
        "timed-out acquisition did not close its owning connection");
  service.AnswerInhibit(0);
  service.inhibit_mode = Mode::kSuccess;
  inhibitor->SetEnabled(true);
  Wait([&] { return service.inhibits.size() == 2; }, "timeout stranded retry");
  inhibitor.reset();
  service.Clean();
  Check(service.releases.size() == 1, "retry after timeout leaked");
}

void ReleaseFailure(Mode mode) {
  ScreenSaver service;
  service.release_mode = mode;
  GtkProbe gtk;
  auto inhibitor = gtk.Create();
  inhibitor->SetEnabled(true);
  Wait([&] { return service.inhibits.size() == 1; }, "Inhibit absent");
  Prompt([&] { inhibitor.reset(); });
  Wait([&] { return service.releases.size() == 1; }, "UnInhibit absent");
  service.Clean();
  Check(service.disconnect_cleanup == 1,
        "failed/timed-out release did not close the private connection");
  if (mode == Mode::kHold) service.AnswerRelease(0);
}

void ZeroCookie() {
  ScreenSaver service;
  service.next_cookie = 0;
  GtkProbe gtk;
  auto inhibitor = gtk.Create();
  inhibitor->SetEnabled(true);
  Wait([&] { return service.inhibits.size() == 1; }, "Inhibit absent");
  inhibitor->Dispose();
  service.Clean();
  Check(service.releases.size() == 1 && service.releases[0].cookie == 0,
        "zero D-Bus cookie was treated as GTK's failure sentinel");
}

void MissingService() {
  ScreenSaver service;
  service.DropName();
  GtkProbe gtk;
  auto inhibitor = gtk.Create();
  inhibitor->SetEnabled(true);
  Wait([&] { return service.opened == 1 && service.peers.empty(); },
       "absent service left an attempt pending");
  Check(service.inhibits.empty(), "called an unowned mock");
  service.OwnName();
  inhibitor->SetEnabled(true);
  Wait([&] { return service.inhibits.size() == 1; }, "absent-service retry stuck");
  inhibitor.reset();
  service.Clean();
}

void ServiceOwnerChanges() {
  ScreenSaver old_service;
  GtkProbe gtk;
  auto old_inhibitor = gtk.Create();
  old_inhibitor->SetEnabled(true);
  Wait([&] { return old_service.inhibits.size() == 1; }, "old Inhibit absent");
  Spin();
  old_service.DropName();
  {
    ScreenSaver replacement;
    auto new_inhibitor = gtk.Create();
    new_inhibitor->SetEnabled(true);
    Wait([&] { return replacement.inhibits.size() == 1; }, "new Inhibit absent");
    Check(old_service.inhibits[0].cookie == replacement.inhibits[0].cookie,
          "service replacement fixture did not reuse the cookie");
    old_inhibitor.reset();
    Wait([&] { return old_service.releases.size() == 1; },
         "UnInhibit was not pinned to the service that issued the cookie");
    Check(replacement.releases.empty() && replacement.cookies.size() == 1,
          "old cookie was sent to the replacement service");
    new_inhibitor.reset();
    replacement.Clean();
  }
  old_service.Clean();
}

void CapturedContext() {
  GMainContext* previous = test_context;
  test_context = g_main_context_new();
  g_main_context_push_thread_default(test_context);
  {
    ScreenSaver service;
    GtkProbe gtk;
    auto inhibitor = gtk.Create();
    g_main_context_pop_thread_default(test_context);
    inhibitor->SetEnabled(true);
    Wait([&] { return service.inhibits.size() == 1; },
         "acquisition escaped the captured main context");
    inhibitor.reset();
    service.Clean();
  }
  g_main_context_unref(test_context);
  test_context = previous;
}

void MissingAddress() {
  const char* address = g_getenv("DBUS_SESSION_BUS_ADDRESS");
  Check(!address || !*address, "missing-address fixture still has an address");
  GtkProbe gtk;
  auto inhibitor = gtk.Create();
  Prompt([&] { inhibitor->SetEnabled(true); });
  Spin();
  inhibitor->SetEnabled(true);
  Check(gtk.acquires == 2, "missing address left a stuck fallback attempt");
  inhibitor->SetEnabled(false);
  gtk.cookie = 71;
  inhibitor->SetEnabled(true);
  inhibitor.reset();
  Check(gtk.releases == std::vector<guint>{71}, "missing address bypassed GTK");
}

void ConnectionError() {
  GtkProbe gtk;
  auto inhibitor = gtk.Create();
  Prompt([&] { inhibitor->SetEnabled(true); });
  Wait([&] {
    inhibitor->SetEnabled(true);
    return gtk.acquires == 2;
  }, "connection error left a stuck attempt");
  inhibitor.reset();
  Spin();
  Check(gtk.releases.empty(), "connection error fabricated a GTK cookie");
}

class StalledSocket {
 public:
  StalledSocket() {
    const char* directory = g_getenv("EASYTIMER_INHIBIT_TEST_DIR");
    Check(directory != nullptr, "missing private socket directory");
    path_ = std::string(directory) + "/stalled.sock";
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    Check(path_.size() < sizeof(address.sun_path), "private socket path too long");
    std::memcpy(address.sun_path, path_.c_str(), path_.size() + 1);
    listener_ = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    Check(listener_ >= 0, "socket failed");
    Check(bind(listener_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) ==
                  0 &&
              listen(listener_, 4) == 0,
          "could not listen on private stalled socket");
    g_autofree gchar* escaped = g_dbus_address_escape_value(path_.c_str());
    // Set before starting GIO workers, so no thread races environment mutation.
    const std::string bus_address = std::string("unix:path=") + escaped;
    Check(setenv("DBUS_SESSION_BUS_ADDRESS", bus_address.c_str(), 1) == 0,
          "could not select private stalled socket");
  }

  ~StalledSocket() {
    if (peer_ >= 0) close(peer_);
    close(listener_);
    unlink(path_.c_str());
  }

  void Accept() {
    Wait([&] {
      peer_ = accept4(listener_, nullptr, nullptr, SOCK_CLOEXEC | SOCK_NONBLOCK);
      return peer_ >= 0;
    }, "async connection did not reach stalled private socket");
  }

  void Closed() {
    Wait([&] {
      char bytes[256];
      return recv(peer_, bytes, sizeof(bytes), MSG_DONTWAIT) == 0;
    }, "cancelled/timed-out connection did not close its socket");
    close(peer_);
    peer_ = -1;
  }

 private:
  std::string path_;
  int listener_ = -1;
  int peer_ = -1;
};

void ConnectionTimeout() {
  StalledSocket socket;
  GtkProbe gtk;
  auto inhibitor = gtk.Create();
  Prompt([&] { inhibitor->SetEnabled(true); });
  socket.Accept();
  socket.Closed();
  Check(gtk.acquires == 1, "timeout retried itself indefinitely");
  inhibitor->SetEnabled(true);
  socket.Accept();
  Prompt([&] { inhibitor.reset(); });
  socket.Closed();
  Check(gtk.acquires == 2 && gtk.releases.empty(),
        "connection timeout/cancellation corrupted GTK state");
  Spin();
}

void Run(const char* name, const std::function<void()>& test) {
  test();
  std::cout << "PASS " << name << '\n';
}

}

int main(int argc, char** argv) {
  // Check before any GIO call: an accidental direct execution must never reach
  // the user's session bus, even when the environment contains its address.
  const char* marker = std::getenv(kMarker);
  if (!marker || std::strcmp(marker, "1") != 0) {
    std::cerr << "REFUSE: run via run_inhibit.sh inside its private dbus-run-session\n";
    return 2;
  }
  try {
    const std::string mode = argc > 1 ? argv[1] : "";
    if (mode == "--flatpak") {
      Check(g_getenv("FLATPAK_ID") != nullptr, "FLATPAK_ID fixture missing");
      Run("FLATPAK_ID presence suppresses fallback", [] { FlatpakSuppression(true); });
    } else if (mode == "--missing-address") {
      Run("absent/empty session address keeps GTK first", MissingAddress);
    } else if (mode == "--connection-error") {
      Run("connection error permits retry and cleanup", ConnectionError);
    } else if (mode == "--stalled-connection") {
      Run("bounded connection setup and nonblocking cancellation", ConnectionTimeout);
    } else {
      Check(mode.empty(), "unknown test mode");
      Check(g_getenv("DBUS_SESSION_BUS_ADDRESS") != nullptr,
            "private session bus address missing");
      Run("GTK success avoids fallback", GtkSuccess);
      Run("GTK failure uses fallback and releases", FallbackSuccess);
      Run("injected Flatpak detector suppresses fallback", [] { FlatpakSuppression(); });
      Run("disable releases late cookie", [] { LateReply(false, false); });
      Run("Dispose releases late cookie and is terminal", [] { LateReply(true, false); });
      Run("destructor releases late cookie without blocking", [] { LateReply(false, true); });
      Run("late cleanup does not retain GTK captures", GtkCapturesExpire);
      Run("rapid toggle handles out-of-order success", [] { RapidToggle(false); });
      Run("rapid toggle handles stale error", [] { RapidToggle(true); });
      Run("rapid toggles during connection setup", RapidToggleDuringConnect);
      Run("reenable during pending release", ToggleDuringRelease);
      Run("reenable retries GTK before fallback", GtkSucceedsOnReenable);
      Run("Inhibit error cleanup and retry", [] { InhibitFailure(Mode::kError); });
      Run("malformed reply cleanup and retry", [] { InhibitFailure(Mode::kMalformed); });
      Run("Inhibit timeout cleanup and retry", InhibitTimeout);
      Run("UnInhibit error cleanup", [] { ReleaseFailure(Mode::kError); });
      Run("UnInhibit timeout cleanup", [] { ReleaseFailure(Mode::kHold); });
      Run("zero D-Bus cookie is released", ZeroCookie);
      Run("unavailable service cleanup and retry", MissingService);
      Run("release stays pinned to original service owner", ServiceOwnerChanges);
      Run("callbacks stay on captured main context", CapturedContext);
    }
    Spin();
  } catch (const std::exception& error) {
    std::cerr << "FAIL " << error.what() << '\n';
    return 1;
  }
}
