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
		const upstream = await fetch(env.ORIGIN + path, {
			cf: { cacheEverything: true, cacheTtl: 3600 },
		});
		const headers = new Headers(upstream.headers);
		headers.set("Cross-Origin-Opener-Policy", "same-origin");
		headers.set("Cross-Origin-Embedder-Policy", "require-corp");
		return new Response(upstream.body, {
			status: upstream.status,
			headers,
		});
	},
};
