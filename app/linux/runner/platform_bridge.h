#ifndef EASYTIMER_PLATFORM_BRIDGE_H_
#define EASYTIMER_PLATFORM_BRIDGE_H_

#include <flutter_linux/flutter_linux.h>

void easytimer_platform_attach(FlView* view, GtkApplication* application,
                               GtkWindow* window);

#endif
