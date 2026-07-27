// Self-destructing service worker.
//
// The site briefly shipped a threaded build whose PWA service worker cached the
// app and injected COOP/COEP headers. That build could not link on a first
// visit or a hard refresh (shared-memory LinkError), so it was replaced with a
// single-threaded build that uses no service worker at all. But a service
// worker outlives the deploy that shipped it: every browser that visited the
// threaded build still has the old worker registered, still controlling the
// page and still able to serve the broken build from its cache.
//
// This file is deployed AT THE OLD WORKER'S URL (index.service.worker.js). On a
// returning visitor's next navigation the browser's update check fetches it,
// finds new bytes, and swaps it in; it then deletes every cache on the origin,
// unregisters itself, and reloads any open tabs so they load clean from the
// network. First-time visitors never fetch it at all.
//
// Deployed by .github/workflows/godot-web-pages.yml, not by the Godot export
// (the export no longer emits a service worker). Harmless to keep deploying
// forever; it only ever runs in browsers that hold the stale registration.
self.addEventListener('install', () => {
	self.skipWaiting();
});

self.addEventListener('activate', (event) => {
	event.waitUntil((async () => {
		const keys = await caches.keys();
		await Promise.all(keys.map((key) => caches.delete(key)));
		await self.registration.unregister();
		const clients = await self.clients.matchAll({ type: 'window' });
		for (const client of clients) {
			client.navigate(client.url);
		}
	})());
});
