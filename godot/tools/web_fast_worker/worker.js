// Header-injecting proxy for the threaded browser demo.
//
// The threaded wasm build needs cross-origin isolation (COOP/COEP) to link its
// shared memory, GitHub Pages cannot send custom headers, and Cloudflare Pages
// cannot host the build at all (index.side.wasm is 41 MiB against a 25 MiB
// per-file cap). So nothing is hosted here: this Worker streams the files from
// GitHub Pages and adds the two headers. Real response headers, so first
// visits and hard refreshes both work -- the service-worker approach broke on
// exactly those two paths, which is why it was abandoned.
//
// Every subresource comes back through this same origin, which is what
// COEP: require-corp demands.
export default {
	async fetch(request, env) {
		const url = new URL(request.url);
		let path = url.pathname;
		if (path.endsWith("/")) {
			path += "index.html";
		}
		// No cache hints: cacheTtl caches EVERY status, and an hour-long cached
		// 404 (from fetching /fast/ before a deploy landed) once took the whole
		// site down from the worker's point of view. GitHub Pages already sends
		// cache-control: max-age=600 and sits on its own CDN; defer to that.
		// CACHE_BUST namespaces the edge cache away from anything poisoned
		// under the old policy (GitHub ignores query strings on static files).
		const upstream = await fetch(
			env.ORIGIN + path + "?cb=" + env.CACHE_BUST);
		const headers = new Headers(upstream.headers);
		headers.set("Cross-Origin-Opener-Policy", "same-origin");
		headers.set("Cross-Origin-Embedder-Policy", "require-corp");
		return new Response(upstream.body, {
			status: upstream.status,
			headers,
		});
	},
};
