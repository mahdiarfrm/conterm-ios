// Page side of native networking: bridges the machine's virtual Ethernet
// socket to a WebSocket the app serves, where the in-app gvisor stack
// forwards the guest's connections to real sockets.
//
// The worker uses the same socket protocol as the in-page proxy
// ({t:accept|send|recv|recv-is-readable} over a shared buffer); here the
// far end is the WebSocket, not another worker. Incoming frames wake a
// pending poll so an idle guest blocks instead of spinning.
function startNativeNetwork(worker, wsUrl, tell) {
  const shared = new SharedArrayBuffer(12 + 65536);
  const ctl = new Int32Array(shared, 0, 1);
  const status = new Int32Array(shared, 4, 1);
  const len = new Int32Array(shared, 8, 1);
  const data = new Uint8Array(shared, 12);

  let ws = null;
  let opening = false;
  let opened = false;
  let incoming = new Uint8Array(0);
  let wake = null;

  function connect() {
    opening = true;
    ws = new WebSocket(wsUrl);
    ws.binaryType = 'arraybuffer';
    ws.onopen = () => { opened = true; opening = false; };
    ws.onmessage = (e) => {
      const more = new Uint8Array(e.data);
      const joined = new Uint8Array(incoming.byteLength + more.byteLength);
      joined.set(incoming, 0); joined.set(more, incoming.byteLength);
      incoming = joined;
      if (wake) { const w = wake; wake = null; w(); }
    };
    ws.onclose = () => { opened = false; opening = false; tell({ t: 'log', s: 'netstack socket closed' }); };
    ws.onerror = () => { opened = false; opening = false; tell({ t: 'log', s: 'netstack socket error' }); };
  }

  function serve(want) {
    const n = Math.min(want, data.byteLength, incoming.byteLength);
    data.set(incoming.subarray(0, n), 0);
    len[0] = n;
    incoming = incoming.subarray(n);
  }
  function answer() { Atomics.store(ctl, 0, 1); Atomics.notify(ctl, 0); }

  const handler = (e) => {
    const m = e.data;
    if (!m || typeof m.t !== 'string') return false;
    switch (m.t) {
      case 'accept':
        if (opened) { data[0] = 1; status[0] = 0; }
        else { data[0] = 0; status[0] = 0; if (!opening && !opened) connect(); }
        break;
      case 'send':
        if (!opened) { status[0] = -1; break; }
        // Copy: the buffer is shared and reused before the socket drains it.
        ws.send(m.buf.slice(0));
        status[0] = 0;
        break;
      case 'recv':
        serve(m.len);
        status[0] = 0;
        break;
      case 'recv-is-readable': {
        if (incoming.byteLength > 0) { data[0] = 1; status[0] = 0; break; }
        const ms = m.timeoutMs || 0;
        if (ms <= 0 || !opened) { data[0] = 0; status[0] = 0; break; }
        let timer = null;
        const finish = () => {
          if (timer) { clearTimeout(timer); timer = null; }
          wake = null;
          data[0] = incoming.byteLength > 0 ? 1 : 0;
          status[0] = 0;
          answer();
        };
        wake = finish;
        timer = setTimeout(finish, ms);
        return true;
      }
      default:
        return false;
    }
    answer();
    return true;
  };

  connect();
  // The machine worker is initialised once, by vm.js, with this buffer in
  // its net field; do not send a competing init here.
  return { sab: shared, handler };
}
