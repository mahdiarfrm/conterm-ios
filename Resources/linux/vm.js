// Page half of the Linux machine (loaded in the hidden web view).
//
// Typed bytes go into a shared buffer the worker blocks on; guest output
// comes back as worker messages and is forwarded to the app. No UI.
(() => {
  const app = window.webkit && window.webkit.messageHandlers
    && window.webkit.messageHandlers.conterm;
  const tell = (m) => { if (app) app.postMessage(m); };

  if (typeof SharedArrayBuffer === 'undefined') {
    tell({ t: 'fatal', s: 'The web view gave no SharedArrayBuffer '
      + '(crossOriginIsolated=' + self.crossOriginIsolated + ').' });
    return;
  }

  // Input: one Int32 flag (0 empty, 1 full), one length, then the bytes.
  // The page fills it only when it is empty; the worker empties it and
  // asks for more. One chunk at a time, so a size announcement is never
  // glued to typed bytes.
  const CAP = 1 << 16;
  const sab = new SharedArrayBuffer(8 + CAP);
  const ctl = new Int32Array(sab, 0, 2);
  const data = new Uint8Array(sab, 8);
  const queue = [];

  function pump() {
    if (!queue.length || Atomics.load(ctl, 0) !== 0) return;
    const chunk = queue.shift();
    data.set(chunk, 0);
    ctl[1] = chunk.length;
    Atomics.store(ctl, 0, 1);
    Atomics.notify(ctl, 0);
  }
  function push(bytes) {
    for (let i = 0; i < bytes.length; i += CAP) {
      queue.push(bytes.subarray(i, Math.min(i + CAP, bytes.length)));
    }
    pump();
  }

  const decode = (s) => {
    const bin = atob(s);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  };
  const encode = (bytes) => {
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) {
      s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return btoa(s);
  };

  // Coalesce output per event-loop turn: the emulator writes a few bytes
  // at a time, and one app message per write would cost more than the
  // bytes. A MessagePort is used rather than a timer, which is throttled
  // in a backgrounded (never-visible) page.
  let parts = [], total = 0, armed = false;
  const flush = new MessageChannel();
  flush.port1.onmessage = () => {
    armed = false;
    if (!total) return;
    const all = new Uint8Array(total);
    let o = 0;
    for (const p of parts) { all.set(p, o); o += p.length; }
    parts = []; total = 0;
    tell({ t: 'out', b: encode(all) });
  };
  function out(bytes) {
    parts.push(bytes); total += bytes.length;
    if (!armed) { armed = true; flush.port2.postMessage(0); }
  }

  const params = new URLSearchParams(location.search);
  const worker = new Worker('worker.js', { type: 'module' });
  worker.onerror = (e) => tell({ t: 'fatal', s: 'worker: ' + (e.message || e) });
  // Networking. 'native' bridges the guest's frames to a real TCP/IP stack
  // in the app over a WebSocket, which forwards to the phone's network:
  // any TCP port, ssh included. 'proxy' runs container2wasm's fetch-based
  // HTTP proxy in a worker instead (HTTP and HTTPS only).
  let net = null;
  let netMode = null;
  const which = params.get('net');
  if (which === 'native') {
    const wsPort = params.get('wsport');
    net = startNativeNetwork(worker, 'ws://127.0.0.1:' + wsPort + '/', tell);
    netMode = 'native';
  } else if (which === 'proxy' || which === '1') {
    const netWorker = new Worker('net.js', { type: 'module' });
    net = startNetwork(worker, netWorker, 'c2w-net-proxy.wasm', tell);
    netMode = 'proxy';
  }
  worker.onmessage = (e) => {
    if (net && net.handler(e)) return;
    const m = e.data;
    switch (m.t) {
      case 'want': case 'took': pump(); break;
      case 'out': out(m.b); break;
      case 'ready': tell({ t: 'ready' }); break;
      case 'exit': flush.port1.onmessage(); tell({ t: 'exit', code: m.code, s: m.s || '' }); break;
      case 'log': tell({ t: 'log', s: String(m.s) }); break;
    }
  };

  window.conterm = {
    input(b64) { push(decode(b64)); },
    // Send the size as a terminal reports it (CSI 8 ; rows ; cols t); the
    // emulator consumes this and resizes the guest console.
    resize(cols, rows) {
      push(new TextEncoder().encode('\x1b[8;' + rows + ';' + cols + 't'));
    },
  };

  worker.postMessage({
    t: 'init',
    sab,
    image: params.get('image') || 'debian.wasm',
    args: ['conterm'],
    env: [],
    trace: params.get('trace') === '1',
    net: net ? { sab: net.sab, mac: mac(), mode: netMode } : null,
  });

  function mac() {
    return '02:XX:XX:XX:XX:XX'.replace(/X/g, () => '0123456789ABCDEF'[Math.floor(Math.random() * 16)]);
  }
  tell({ t: 'page' });
})();
