{{flutter_js}}
{{flutter_build_config}}

const frameMedia = matchMedia(
  "(min-width: 760px) and (min-height: 600px) and (pointer: fine)",
);
const config = {};
const phone = document.getElementById("phone");
const about = document.getElementById("about");

if (frameMedia.matches) {
  // Full-page embedding keeps the on-screen keyboard usable on touch devices.
  config.hostElement = document.getElementById("screen");
  const updateLayout = () => {
    if (!frameMedia.matches && about.contains(document.activeElement)) {
      phone.querySelector("flutter-view")?.focus();
    }
    document.documentElement.classList.toggle("framed", frameMedia.matches);
  };
  updateLayout();
  frameMedia.addEventListener("change", updateLayout);

  const button = document.getElementById("fullscreen");
  button.hidden = !document.fullscreenEnabled;
  // A refused request, e.g. in an iframe without allowfullscreen, keeps the frame.
  button.addEventListener("click", () => phone.requestFullscreen().catch(() => {}));
  document.addEventListener("fullscreenchange", () => {
    phone.querySelector("flutter-view")?.focus();
  });
} else {
  about.remove();
}

_flutter.loader.load({
  config,
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
  onEntrypointLoaded: async (engineInitializer) => {
    const appRunner = await engineInitializer.initializeEngine(config);
    await appRunner.runApp();
    // In embedded mode the engine has already emptied the screen host.
    if (!config.hostElement) phone.remove();
  },
});
