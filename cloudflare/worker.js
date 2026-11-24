// Envelora API relay (Cloudflare Worker)
// Passes every request (login, sync, realtime websocket) to the Supabase project in Mumbai,
// so the app works even on mobile networks that block supabase.co.
// Paste this whole file into the Cloudflare Worker editor and click Deploy.

const UPSTREAM = 'prwvljhkgcpxjxtobcuv.supabase.co';

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === '/' || url.pathname === '/health') {
      return new Response('Envelora relay OK', { headers: { 'content-type': 'text/plain' } });
    }
    url.protocol = 'https:';
    url.hostname = UPSTREAM;
    url.port = '';
    // Same method, headers and body; websocket upgrades (realtime) pass through as well.
    return fetch(new Request(url.toString(), request));
  }
};
