#include "screen_inhibitor.h"

#include <gio/gio.h>

#include <utility>

namespace {

constexpr char kService[] = "org.freedesktop.ScreenSaver";
constexpr char kPath[] = "/org/freedesktop/ScreenSaver";
constexpr int kTimeoutMs = 1000;

bool InFlatpak() {
  // Even an empty marker must prevent direct D-Bus calls from the sandbox.
  return g_getenv("FLATPAK_ID") != nullptr ||
         g_file_test("/.flatpak-info", G_FILE_TEST_EXISTS);
}

class ContextScope {
 public:
  explicit ContextScope(GMainContext* context) : context_(context) {
    g_main_context_push_thread_default(context_);
  }
  ~ContextScope() { g_main_context_pop_thread_default(context_); }

 private:
  GMainContext* context_;
};

// Retired attempts must release only their own cookies. Private connections also
// retire hidden cookies when a reply times out.
class Fallback : public std::enable_shared_from_this<Fallback> {
 public:
  Fallback(GMainContext* context, std::string application, std::string reason)
      : context_(g_main_context_ref(context)),
        application_(std::move(application)),
        reason_(std::move(reason)),
        connecting_(g_cancellable_new()) {}

  ~Fallback() {
    Close();
    g_object_unref(connecting_);
    g_main_context_unref(context_);
  }

  void Start() {
    const gchar* address = g_getenv("DBUS_SESSION_BUS_ADDRESS");
    // Discovering an absent address could autolaunch a bus or block the UI.
    if (!address || !*address) {
      Close();
      return;
    }
    ContextScope context(context_);
    deadline_ = g_timeout_source_new(kTimeoutMs);
    g_source_set_callback(
        deadline_,
        [](gpointer data) -> gboolean {
          auto self = *static_cast<std::shared_ptr<Fallback>*>(data);
          self->Close();
          return G_SOURCE_REMOVE;
        },
        Hold(), [](gpointer data) {
          delete static_cast<std::shared_ptr<Fallback>*>(data);
        });
    g_source_attach(deadline_, context_);

    Connect(address);
  }

  bool active() const {
    return wanted_ && phase_ != Phase::kClosed &&
           (!connection_ || !g_dbus_connection_is_closed(connection_));
  }

  void Release() {
    wanted_ = false;
    if (phase_ == Phase::kConnecting) {
      // No Inhibit has been sent, so cancelling connection setup is safe.
      Close();
    } else if (phase_ == Phase::kHeld) {
      ReleaseCookie();
    }
    // Do not cancel Inhibit: cancellation can hide an already-acquired cookie.
    // Its bounded callback will release a late cookie even after destruction.
  }

 private:
  enum class Phase { kConnecting, kAcquiring, kHeld, kReleasing, kClosed };

  gpointer Hold() { return new std::shared_ptr<Fallback>(shared_from_this()); }

  static std::shared_ptr<Fallback> Take(gpointer data) {
    std::unique_ptr<std::shared_ptr<Fallback>> holder(
        static_cast<std::shared_ptr<Fallback>*>(data));
    return std::move(*holder);
  }

  void StopDeadline() {
    if (!deadline_) return;
    g_source_destroy(deadline_);
    g_source_unref(deadline_);
    deadline_ = nullptr;
  }

  void Connect(const gchar* address) {
    ContextScope context(context_);
    g_dbus_connection_new_for_address(
        address,
        static_cast<GDBusConnectionFlags>(
            G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
            G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
        nullptr, connecting_,
        [](GObject*, GAsyncResult* result, gpointer data) {
          auto self = Take(data);
          self->connection_ =
              g_dbus_connection_new_for_address_finish(result, nullptr);
          self->StopDeadline();
          if (self->connection_)
            g_dbus_connection_set_exit_on_close(self->connection_, FALSE);
          if (!self->connection_ || !self->wanted_) {
            self->Close();
            return;
          }
          self->AcquireCookie();
        },
        Hold());
  }

  void AcquireCookie() {
    ContextScope context(context_);
    phase_ = Phase::kAcquiring;
    g_autoptr(GDBusMessage) message =
        g_dbus_message_new_method_call(kService, kPath, kService, "Inhibit");
    g_dbus_message_set_body(
        message, g_variant_new("(ss)", application_.c_str(), reason_.c_str()));
    // Reading the reply message also identifies the actual service owner. Send
    // UnInhibit to that owner so a replacement service cannot receive an old
    // cookie which happens to match one of its own cookies.
    g_dbus_connection_send_message_with_reply(
        connection_, message, G_DBUS_SEND_MESSAGE_FLAGS_NONE, kTimeoutMs,
        nullptr, nullptr,
        [](GObject* source, GAsyncResult* result, gpointer data) {
          auto self = Take(data);
          g_autoptr(GDBusMessage) reply =
              g_dbus_connection_send_message_with_reply_finish(
                  G_DBUS_CONNECTION(source), result, nullptr);
          GVariant* body = reply ? g_dbus_message_get_body(reply) : nullptr;
          const gchar* sender =
              reply ? g_dbus_message_get_sender(reply) : nullptr;
          if (!reply || g_dbus_message_get_message_type(reply) !=
                            G_DBUS_MESSAGE_TYPE_METHOD_RETURN ||
              !body || !g_variant_is_of_type(body, G_VARIANT_TYPE("(u)")) ||
              !sender || !g_dbus_is_unique_name(sender)) {
            self->Close();
            return;
          }
          self->service_owner_ = sender;
          g_variant_get(body, "(u)", &self->cookie_);
          self->phase_ = Phase::kHeld;
          // Unlike GTK's sentinel, zero is a valid D-Bus uint32 cookie.
          if (!self->wanted_) self->ReleaseCookie();
        },
        Hold());
  }

  void ReleaseCookie() {
    ContextScope context(context_);
    phase_ = Phase::kReleasing;
    g_dbus_connection_call(
        connection_, service_owner_.c_str(), kPath, kService, "UnInhibit",
        g_variant_new("(u)", cookie_), G_VARIANT_TYPE_UNIT,
        G_DBUS_CALL_FLAGS_NO_AUTO_START, kTimeoutMs, nullptr,
        [](GObject* source, GAsyncResult* result, gpointer data) {
          auto self = Take(data);
          g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
              G_DBUS_CONNECTION(source), result, nullptr);
          self->Close();
        },
        Hold());
  }

  void Close() {
    wanted_ = false;
    phase_ = Phase::kClosed;
    StopDeadline();
    g_cancellable_cancel(connecting_);
    if (!connection_) return;
    ContextScope context(context_);
    // Retired attempts must not wait for a server round trip during disposal.
    g_dbus_connection_close(
        connection_, nullptr,
        [](GObject* source, GAsyncResult* result, gpointer) {
          g_dbus_connection_close_finish(G_DBUS_CONNECTION(source), result,
                                          nullptr);
        },
        nullptr);
    g_clear_object(&connection_);
  }

  GMainContext* context_;
  std::string application_;
  std::string reason_;
  GCancellable* connecting_;
  GSource* deadline_ = nullptr;
  GDBusConnection* connection_ = nullptr;
  std::string service_owner_;
  Phase phase_ = Phase::kConnecting;
  guint cookie_ = 0;
  bool wanted_ = true;
};

}

struct ScreenInhibitor::State {
  State(GtkAcquire acquire, GtkRelease release, std::string application,
        std::string reason, FlatpakDetector flatpak)
      : acquire(std::move(acquire)),
        release(std::move(release)),
        application(std::move(application)),
        reason(std::move(reason)),
        flatpak(flatpak ? std::move(flatpak) : FlatpakDetector(InFlatpak)),
        context(g_main_context_ref_thread_default()) {}

  ~State() { g_main_context_unref(context); }

  void Disable() {
    if (gtk_cookie != 0) {
      const guint cookie = gtk_cookie;
      gtk_cookie = 0;
      release(cookie);
    }
    if (fallback) {
      fallback->Release();
      fallback.reset();
    }
  }

  GtkAcquire acquire;
  GtkRelease release;
  std::string application;
  std::string reason;
  FlatpakDetector flatpak;
  GMainContext* context;
  std::shared_ptr<Fallback> fallback;
  guint gtk_cookie = 0;
  bool disposed = false;
};

ScreenInhibitor::ScreenInhibitor(GtkAcquire gtk_acquire, GtkRelease gtk_release,
                                std::string application_name,
                                std::string reason,
                                FlatpakDetector in_flatpak)
    : state_(std::make_shared<State>(
          std::move(gtk_acquire), std::move(gtk_release),
          std::move(application_name), std::move(reason), std::move(in_flatpak))) {}

ScreenInhibitor::~ScreenInhibitor() { Dispose(); }

void ScreenInhibitor::SetEnabled(bool enabled) {
  if (state_->disposed) return;
  if (!enabled) {
    state_->Disable();
    return;
  }
  if (state_->gtk_cookie != 0 ||
      (state_->fallback && state_->fallback->active()))
    return;
  state_->fallback.reset();
  state_->gtk_cookie = state_->acquire();
  if (state_->gtk_cookie != 0 || state_->flatpak()) return;
  state_->fallback = std::make_shared<Fallback>(
      state_->context, state_->application, state_->reason);
  state_->fallback->Start();
}

void ScreenInhibitor::Dispose() {
  if (state_->disposed) return;
  state_->disposed = true;
  state_->Disable();
  state_->acquire = {};
  state_->release = {};
  state_->flatpak = {};
}
