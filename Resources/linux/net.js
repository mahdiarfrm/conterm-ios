// The network stack's worker: a TCP/IP stack and HTTP proxy compiled to
// WASI (container2wasm's c2w-net-proxy), fed the machine's Ethernet frames
// over a socket the page relays, doing its HTTP through the page, which
// asks the app.
//
// Adapted from container2wasm's examples/wasi-browser/htdocs/stack-worker.js.
import { WASI } from './shim/index.js';
import { Ciovec } from './shim/wasi_defs.js';
import { Subscription, Event, EventType } from './poll.js';
import { Link, socketShim } from './netlink.js';

const ERRNO_INVAL = 28;
const CERT_FD = 3;
const LISTEN_FD = 4;
const CONN_FD = 5;

function wire(wasi, link) {
  const imp = wasi.wasiImport;
  const mem = () => new Uint8Array(wasi.inst.exports.memory.buffer);
  const view = () => new DataView(wasi.inst.exports.memory.buffer);
  let cert = new Uint8Array(0);

  // The stack writes its certificate authority to fd 3 and closes it; the
  // machine gets it as a file so the guest trusts the proxy's HTTPS.
  const _fd_close = imp.fd_close;
  imp.fd_close = (fd) => {
    if (fd === CERT_FD) { link.call({ t: 'send_cert', buf: cert }); return 0; }
    return _fd_close.apply(imp, [fd]);
  };
  const _fd_fdstat_get = imp.fd_fdstat_get;
  imp.fd_fdstat_get = (fd, ptr) => (fd === CERT_FD ? 0 : _fd_fdstat_get.apply(imp, [fd, ptr]));
  imp.fd_fdstat_set_flags = () => 0;
  const _fd_write = imp.fd_write;
  imp.fd_write = (fd, iovs_ptr, iovs_len, nwritten_ptr) => {
    if (fd !== 1 && fd !== 2 && fd !== CERT_FD) return _fd_write.apply(imp, [fd, iovs_ptr, iovs_len, nwritten_ptr]);
    const iovecs = Ciovec.read_bytes_array(view(), iovs_ptr, iovs_len);
    let total = 0;
    for (const iov of iovecs) {
      if (iov.buf_len === 0) continue;
      const bytes = mem().slice(iov.buf, iov.buf + iov.buf_len);
      if (fd === CERT_FD) {
        const joined = new Uint8Array(cert.length + bytes.length);
        joined.set(cert, 0); joined.set(bytes, cert.length);
        cert = joined;
      } else {
        postMessage({ t: 'log', s: 'stack: ' + new TextDecoder().decode(bytes).trimEnd() });
      }
      total += bytes.length;
    }
    view().setUint32(nwritten_ptr, total, true);
    return 0;
  };
  imp.poll_oneoff = (in_ptr, out_ptr, nsubscriptions, nevents_ptr) => {
    if (nsubscriptions === 0) return ERRNO_INVAL;
    const v = view();
    const subs = Subscription.read_bytes_array(v, in_ptr, nsubscriptions);
    let connSub = null, clockSub = null;
    let timeout = Number.MAX_VALUE;
    for (const sub of subs) {
      if (sub.u.tag.variant === 'fd_read') {
        if (sub.u.data.fd !== CONN_FD) return ERRNO_INVAL;
        connSub = sub;
      } else if (sub.u.tag.variant === 'clock') {
        if (sub.u.data.timeout < timeout) { timeout = sub.u.data.timeout; clockSub = sub; }
      } else {
        return ERRNO_INVAL;
      }
    }
    const events = [];
    if (connSub || clockSub) {
      const ready = link.readable(timeout === Number.MAX_VALUE ? 0 : timeout / 1e6);
      if (ready === null) return ERRNO_INVAL;
      if (ready && connSub) {
        const ev = new Event();
        ev.userdata = connSub.userdata; ev.error = 0; ev.type = new EventType('fd_read');
        events.push(ev);
      }
      if (clockSub) {
        const ev = new Event();
        ev.userdata = clockSub.userdata; ev.error = 0; ev.type = new EventType('clock');
        events.push(ev);
      }
    }
    Event.write_bytes_array(v, out_ptr, events);
    v.setUint32(nevents_ptr, events.length, true);
    return 0;
  };
}

// The stack's HTTP goes to the page, one request at a time per id.
function http(wasi, link) {
  const mem = () => new Uint8Array(wasi.inst.exports.memory.buffer);
  const view = () => new DataView(wasi.inst.exports.memory.buffer);
  return {
    http_send(addressP, addresslen, reqP, reqlen, idP) {
      const address = mem().slice(addressP, addressP + addresslen);
      const req = mem().slice(reqP, reqP + reqlen);
      const id = link.call({ t: 'http_send', address, req });
      if (id < 0) return ERRNO_INVAL;
      view().setUint32(idP, id, true);
      return 0;
    },
    http_writebody(id, bodyP, bodylen, nwrittenP, isEOF) {
      const body = mem().slice(bodyP, bodyP + bodylen);
      if (link.call({ t: 'http_writebody', id, body, isEOF: isEOF === 1 }) < 0) return ERRNO_INVAL;
      view().setUint32(nwrittenP, bodylen, true);
      return 0;
    },
    http_isreadable(id, isOKP) {
      if (link.call({ t: 'http_isreadable', id }) < 0) return ERRNO_INVAL;
      view().setUint32(isOKP, link.data[0] === 1 ? 1 : 0, true);
      return 0;
    },
    http_recv(id, respP, bufsize, respsizeP, isEOFP) {
      const status = link.call({ t: 'http_recv', id, len: bufsize });
      if (status < 0) return ERRNO_INVAL;
      const bytes = link.taken();
      mem().set(bytes, respP);
      view().setUint32(respsizeP, bytes.length, true);
      view().setUint32(isEOFP, status === 1 ? 1 : 0, true);
      return 0;
    },
    http_readbody(id, bodyP, bufsize, bodysizeP, isEOFP) {
      const status = link.call({ t: 'http_readbody', id, len: bufsize });
      if (status < 0) return ERRNO_INVAL;
      const bytes = link.taken();
      mem().set(bytes, bodyP);
      view().setUint32(bodysizeP, bytes.length, true);
      view().setUint32(isEOFP, status === 1 ? 1 : 0, true);
      return 0;
    },
  };
}

onmessage = async (e) => {
  const m = e.data;
  if (!m || m.t !== 'init') return;
  const link = new Link(m.sab);
  try {
    const fds = [undefined, undefined, undefined, undefined, undefined, undefined];
    const args = ['stack', '--certfd=' + CERT_FD, '--net-listenfd=' + LISTEN_FD];
    const wasi = new WASI(args, [], fds);
    wire(wasi, link);
    socketShim(wasi, link, LISTEN_FD, CONN_FD);
    let module;
    try {
      module = await WebAssembly.compileStreaming(fetch(m.image));
    } catch (err) {
      const resp = await fetch(m.image);
      if (!resp.ok) throw new Error('stack image ' + resp.status);
      module = await WebAssembly.compile(await resp.arrayBuffer());
    }
    const inst = await WebAssembly.instantiate(module, {
      wasi_snapshot_preview1: wasi.wasiImport,
      env: http(wasi, link),
    });
    const code = wasi.start(inst);
    postMessage({ t: 'log', s: 'stack exited ' + code });
  } catch (err) {
    postMessage({ t: 'log', s: 'stack failed: ' + ((err && err.message) || err) });
  }
};
