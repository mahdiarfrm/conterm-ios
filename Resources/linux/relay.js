// Page side of proxy networking: relays frames between the machine worker
// and the proxy-stack worker, and makes the stack's HTTP fetches against
// the app's own /fetch endpoint so CORS never applies to the guest.
//
// Adapted from container2wasm's examples/wasi-browser/htdocs/stack.js.
function startNetwork(vmWorker, netWorker, stackImage, tell) {
  // Two byte streams: machine to stack, stack to machine. Each side
  // appends to its send stream and takes from its receive stream.
  const toStack = { buf: new Uint8Array(0), wake: null };
  const toMachine = { buf: new Uint8Array(0), wake: null };
  const cert = { buf: new Uint8Array(0), done: false };
  const stackShared = new SharedArrayBuffer(12 + 65536);
  const machineShared = new SharedArrayBuffer(12 + 65536);
  const stackHandler = relay('stack', stackShared, { send: toMachine, recv: toStack }, cert, tell);
  const machineHandler = relay('machine', machineShared, { send: toStack, recv: toMachine }, cert, tell);
  netWorker.onmessage = (e) => {
    if (stackHandler(e)) return;
    if (e.data && e.data.t === 'log') tell({ t: 'log', s: e.data.s });
  };
  netWorker.onerror = (e) => tell({ t: 'log', s: 'stack worker: ' + (e.message || e) });
  netWorker.postMessage({ t: 'init', sab: stackShared, image: stackImage });
  return { sab: machineShared, handler: machineHandler };
}

// With ?trace=1: every frame's length on each stream, and anything odd.
let traceFrames = new URLSearchParams(location.search).get('trace') === '1';
function frameTracer(label, tell) {
  let head = new Uint8Array(0), need = -1, count = 0, frame = new Uint8Array(0);
  const describe = (f) => {
    if (f.byteLength < 14) return 'short';
    const et = (f[12] << 8 | f[13]);
    if (et === 0x0806) return 'ARP';
    if (et !== 0x0800) return 'ethertype 0x' + et.toString(16);
    const proto = f[23];
    const dst = f[30] + '.' + f[31] + '.' + f[32] + '.' + f[33];
    const src = f[26] + '.' + f[27] + '.' + f[28] + '.' + f[29];
    const ihl = (f[14] & 0x0f) * 4;
    const l4 = 14 + ihl;
    if (proto === 6) {
      const flags = f[l4 + 13];
      const names = [];
      if (flags & 0x02) names.push('SYN'); if (flags & 0x10) names.push('ACK');
      if (flags & 0x01) names.push('FIN'); if (flags & 0x04) names.push('RST'); if (flags & 0x08) names.push('PSH');
      const dport = (f[l4 + 2] << 8 | f[l4 + 3]);
      return 'TCP ' + src + '->' + dst + ':' + dport + ' ' + names.join(',');
    }
    if (proto === 17) {
      const dport = (f[l4 + 2] << 8 | f[l4 + 3]);
      return 'UDP ' + src + '->' + dst + ':' + dport;
    }
    return 'IP proto ' + proto + ' ' + src + '->' + dst;
  };
  return (chunk) => {
    let bytes = new Uint8Array(chunk);
    while (bytes.byteLength) {
      if (need < 0) {
        const take = Math.min(4 - head.byteLength, bytes.byteLength);
        const joined = new Uint8Array(head.byteLength + take);
        joined.set(head, 0); joined.set(bytes.subarray(0, take), head.byteLength);
        head = joined; bytes = bytes.subarray(take);
        if (head.byteLength < 4) return;
        need = (head[0] << 24 | head[1] << 16 | head[2] << 8 | head[3]) >>> 0;
        head = new Uint8Array(0); frame = new Uint8Array(0);
        count++;
      }
      const take = Math.min(need, bytes.byteLength);
      const part = bytes.subarray(0, take);
      const grown = new Uint8Array(frame.byteLength + part.byteLength);
      grown.set(frame, 0); grown.set(part, frame.byteLength); frame = grown;
      bytes = bytes.subarray(take); need -= take;
      if (need === 0) {
        need = -1;
        if (count <= 24) tell({ t: 'log', s: label + ' #' + count + ' ' + frame.byteLength + 'B ' + describe(frame) });
      }
    }
  };
}

function relay(name, shared, conn, cert, tell) {
  const tracer = traceFrames ? frameTracer(name + ' sends', tell) : null;
  const ctl = new Int32Array(shared, 0, 1);
  const status = new Int32Array(shared, 4, 1);
  const len = new Int32Array(shared, 8, 1);
  const data = new Uint8Array(shared, 12);
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  let accepted = false;
  let waiting = null;
  const requests = {};
  let nextID = 1;

  // Move up to `want` bytes of `bytes` into the shared buffer; return the rest.
  function serve(bytes, want) {
    const n = Math.min(want, data.byteLength, bytes.byteLength);
    data.set(bytes.subarray(0, n), 0);
    len[0] = n;
    return bytes.subarray(n);
  }
  function append(stream, more) {
    const joined = new Uint8Array(stream.buf.byteLength + more.byteLength);
    joined.set(stream.buf, 0);
    joined.set(new Uint8Array(more), stream.buf.byteLength);
    stream.buf = joined;
    if (stream.wake) { const w = stream.wake; stream.wake = null; w(); }
  }
  function answer() {
    Atomics.store(ctl, 0, 1);
    Atomics.notify(ctl, 0);
  }

  const FORBIDDEN = new Set(['host', 'content-length', 'connection', 'keep-alive', 'transfer-encoding',
    'accept-encoding', 'proxy-connection', 'te', 'trailer', 'upgrade', 'expect']);

  function startFetch(r) {
    const headers = {};
    for (const [k, v] of Object.entries(r.headers)) {
      if (!FORBIDDEN.has(k.toLowerCase()) && !k.toLowerCase().startsWith('proxy-')) headers[k] = v;
    }
    const init = { method: r.method, headers, cache: 'no-store', redirect: 'follow', credentials: 'omit' };
    if (r.method !== 'GET' && r.method !== 'HEAD' && r.body.length) {
      let size = 0; for (const p of r.body) size += p.byteLength;
      const body = new Uint8Array(size); let o = 0;
      for (const p of r.body) { body.set(p, o); o += p.byteLength; }
      init.body = body;
    }
    r.body = [];
    if (traceFrames) tell({ t: 'log', s: 'proxy fetch ' + r.method + ' ' + r.address });
    fetch(location.origin + '/fetch?url=' + encodeURIComponent(r.address), init).then(async (resp) => {
      if (traceFrames) tell({ t: 'log', s: 'proxy got ' + resp.status + ' for ' + r.address });
      const h = {};
      resp.headers.forEach((v, k) => { h[k] = v; });
      r.response = encoder.encode(JSON.stringify({ status: resp.status, statusText: resp.statusText || 'OK', headers: h }));
      if (!resp.body) { r.done = true; return; }
      const reader = resp.body.getReader();
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        r.chunks.push(value);
      }
      r.done = true;
    }).catch((err) => {
      tell({ t: 'log', s: 'fetch ' + r.address + ': ' + err });
      r.response = encoder.encode(JSON.stringify({ status: 503, statusText: 'Service Unavailable', headers: {} }));
      r.done = true;
    });
  }

  return function (e) {
    const m = e.data;
    if (!m || typeof m.t !== 'string') return false;
    switch (m.t) {
      case 'accept':
        accepted = true;
        data[0] = 1;
        status[0] = 0;
        break;
      case 'send':
        if (!accepted) { status[0] = -1; break; }
        if (tracer) tracer(m.buf);
        append(conn.send, m.buf);
        status[0] = 0;
        break;
      case 'recv':
        if (!accepted) { status[0] = -1; break; }
        conn.recv.buf = serve(conn.recv.buf, m.len);
        status[0] = 0;
        break;
      case 'recv-is-readable': {
        if (conn.recv.buf.byteLength > 0) { data[0] = 1; status[0] = 0; break; }
        const ms = m.timeoutMs || 0;
        if (ms <= 0) { data[0] = 0; status[0] = 0; break; }
        // Answer when bytes arrive, or when the time is up, whichever first.
        let timer = null;
        const finish = () => {
          if (timer) { clearTimeout(timer); timer = null; }
          conn.recv.wake = null;
          data[0] = conn.recv.buf.byteLength > 0 ? 1 : 0;
          status[0] = 0;
          answer();
        };
        conn.recv.wake = finish;
        timer = setTimeout(finish, ms);
        return true;
      }
      case 'http_send': {
        let req;
        try { req = JSON.parse(decoder.decode(m.req)); } catch (err) { status[0] = -1; break; }
        const id = nextID++;
        if (nextID > 0x7fffffff) nextID = 1;
        requests[id] = {
          address: decoder.decode(m.address), method: req.method || 'GET', headers: req.headers || {},
          body: [], sent: false, response: null, chunks: [], done: false,
        };
        status[0] = id;
        break;
      }
      case 'http_writebody': {
        const r = requests[m.id];
        if (!r) { status[0] = -1; break; }
        if (m.body && m.body.byteLength) r.body.push(new Uint8Array(m.body));
        if (m.isEOF && !r.sent) { r.sent = true; startFetch(r); }
        status[0] = 0;
        break;
      }
      case 'http_isreadable': {
        const r = requests[m.id];
        data[0] = r && r.response ? 1 : 0;
        status[0] = 0;
        break;
      }
      case 'http_recv': {
        const r = requests[m.id];
        if (!r || !r.response) { status[0] = -1; break; }
        r.response = serve(r.response, m.len);
        status[0] = r.response.byteLength === 0 ? 1 : 0;
        break;
      }
      case 'http_readbody': {
        const r = requests[m.id];
        if (!r || !r.response) { status[0] = -1; break; }
        if (r.chunks.length) {
          const rest = serve(r.chunks[0], m.len);
          if (rest.byteLength) r.chunks[0] = rest; else r.chunks.shift();
        } else {
          len[0] = 0;
        }
        if (r.done && r.chunks.length === 0) { status[0] = 1; delete requests[m.id]; }
        else status[0] = 0;
        break;
      }
      case 'send_cert':
        append(cert, m.buf);
        cert.done = true;
        status[0] = 0;
        break;
      case 'recv_cert':
        if (!cert.done) { status[0] = -1; break; }
        cert.buf = serve(cert.buf, m.len || 4096);
        status[0] = cert.buf.byteLength === 0 ? 1 : 0;
        break;
      default:
        return false;
    }
    answer();
    return true;
  };
}
