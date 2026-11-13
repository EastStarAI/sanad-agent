// Sanad web bootstrap.
//
// Flutter generates a bootstrap that registers `flutter_service_worker.js`.
// That generated worker is a tombstone that unregisters itself and provides no
// offline cache, so registration is taken over here: the only service worker
// this app registers is `sw.js`, which owns web push and notification clicks.
// The decision, its offline consequences, and the legacy-cache cleanup are
// documented in docs/technical/web_push_delivery.md.
{{flutter_js}}
{{flutter_build_config}}

(function () {
  if (!('serviceWorker' in navigator)) return;
  var scope = new URL('./', document.baseURI);
  window._sanadServiceWorker = navigator.serviceWorker
    .register(new URL('sw.js', scope).toString(), { scope: scope.pathname })
    .catch(function (error) {
      // A missing worker must not block startup; push capability degrades and
      // Settings reports it instead of the app failing to load.
      console.warn('Sanad service worker registration failed:', error);
    });
})();

_flutter.loader.load();
