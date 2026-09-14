// Worker half of the Linux machine: the WASI emulator, its imports, and a
// console wired to a shared buffer.
//
// The emulator runs as one long WebAssembly call that never returns, so the
// thread cannot receive messages. Input arrives through shared memory the
// thread blocks on; output leaves as postMessage, which a busy thread can
// still do.
import { WASI, PreopenDirectory, File } from './shim/index.js';
import { Iovec, Ciovec, WHENCE_SET } from './shim/wasi_defs.js';
import { Subscription, Event, EventType } from './poll.js';
import { Link, socketShim } from './netlink.js';

const ERRNO_INVAL = 28;
// ?trace=1 on the page logs every console read.
let trace = false;
const ERRNO_AGAIN = 6;
const ERRNO_NOTSUP = 58;

class Console {
  constructor(sab) {
    this.ctl = new Int32Array(sab, 0, 2);
    this.data = new Uint8Array(sab, 8);
    this.pending = new Uint8Array(0);
  }
  // Move a full buffer into `pending` and hand the buffer back.
  take() {
    if (Atomics.load(this.ctl, 0) !== 1) return false;
    const n = this.ctl[1];
    this.pending = this.data.slice(0, n);
    Atomics.store(this.ctl, 0, 0);
    postMessage({ t: 'took' });
    return n > 0;
  }
  // True when a byte is waiting, or one arrives within the timeout.
  readable(ms) {
    if (this.pending.length) return true;
    if (this.take()) return true;
    postMessage({ t: 'want' });
    Atomics.wait(this.ctl, 0, 0, ms);
    return this.take();
  }
  // Up to `len` bytes of what is waiting; never blocks.
  read(len) {
    if (!this.pending.length && !this.take()) return null;
    const n = Math.min(len, this.pending.length);
    const out = this.pending.slice(0, n);
    this.pending = this.pending.slice(n);
    return out;
  }
}

const CERT_FD = 3;
const LISTEN_FD = 4;
const CONN_FD = 5;

// Route the emulator's stdin, stdout and polling to the console, and its
// network socket to the link when there is one.
function wire(wasi, con, link) {
  const imp = wasi.wasiImport;
  // The image imports sock_accept; the 0.2.9 shim lacks it. Unused here.
  if (!imp.sock_accept) imp.sock_accept = () => ERRNO_NOTSUP;
  const _fd_read = imp.fd_read;
  imp.fd_read = (fd, iovs_ptr, iovs_len, nread_ptr) => {
    if (fd !== 0) return _fd_read.apply(imp, [fd, iovs_ptr, iovs_len, nread_ptr]);
    const view = new DataView(wasi.inst.exports.memory.buffer);
    const mem = new Uint8Array(wasi.inst.exports.memory.buffer);
    const iovecs = Iovec.read_bytes_array(view, iovs_ptr, iovs_len);
    let nread = 0;
    for (const iov of iovecs) {
      if (iov.buf_len === 0) continue;
      const bytes = con.read(iov.buf_len);
      if (bytes === null) break;
      mem.set(bytes, iov.buf);
      nread += bytes.length;
      if (trace) postMessage({ t: 'log', s: 'stdin read asked ' + iov.buf_len + ' got ' + bytes.length + ' ' + JSON.stringify(new TextDecoder().decode(bytes).slice(0, 24)) });
      break;
    }
    // stdin is non-blocking: nothing waiting is EAGAIN, not end of file.
    if (nread === 0) return ERRNO_AGAIN;
    view.setUint32(nread_ptr, nread, true);
    return 0;
  };

  const _fd_write = imp.fd_write;
  imp.fd_write = (fd, iovs_ptr, iovs_len, nwritten_ptr) => {
    if (fd !== 1 && fd !== 2) return _fd_write.apply(imp, [fd, iovs_ptr, iovs_len, nwritten_ptr]);
    const view = new DataView(wasi.inst.exports.memory.buffer);
    const mem = new Uint8Array(wasi.inst.exports.memory.buffer);
    const iovecs = Ciovec.read_bytes_array(view, iovs_ptr, iovs_len);
    let total = 0;
    for (const iov of iovecs) {
      if (iov.buf_len === 0) continue;
      const bytes = mem.slice(iov.buf, iov.buf + iov.buf_len);
      postMessage({ t: 'out', b: bytes }, [bytes.buffer]);
      total += iov.buf_len;
    }
    view.setUint32(nwritten_ptr, total, true);
    return 0;
  };

  imp.poll_oneoff = (in_ptr, out_ptr, nsubscriptions, nevents_ptr) => {
    if (nsubscriptions === 0) return ERRNO_INVAL;
    const view = new DataView(wasi.inst.exports.memory.buffer);
    const subs = Subscription.read_bytes_array(view, in_ptr, nsubscriptions);
    let stdinSub = null, clockSub = null, connSub = null;
    let timeout = Number.MAX_VALUE;
    for (const sub of subs) {
      if (sub.u.tag.variant === 'fd_read') {
        if (sub.u.data.fd === 0) stdinSub = sub;
        else if (link && sub.u.data.fd === CONN_FD) connSub = sub;
        else return ERRNO_INVAL;
      } else if (sub.u.tag.variant === 'clock') {
        if (sub.u.data.timeout < timeout) { timeout = sub.u.data.timeout; clockSub = sub; }
      } else {
        return ERRNO_INVAL;
      }
    }
    const events = [];
    const ms = timeout === Number.MAX_VALUE ? Infinity : timeout / 1e6;
    // A socket read that would otherwise block forever must still let the
    // page deliver inbound data: park on the link with a real timeout, which
    // the arrival of data cuts short. Zero here would spin and starve the
    // page's socket pump, stalling anything that spans several packets.
    const BLOCK_MS = 30000;
    const pushEvent = (sub) => {
      const ev = new Event();
      ev.userdata = sub.userdata; ev.error = 0; ev.type = new EventType('fd_read');
      events.push(ev);
    };
    if (connSub && !stdinSub) {
      // The network's own select: wait on the link, not the console.
      const ready = link.readable(ms === Infinity ? BLOCK_MS : ms);
      if (ready === null) return ERRNO_INVAL;
      if (ready) pushEvent(connSub);
    } else if (connSub && stdinSub) {
      // Both watched at once (a program reading stdin and a socket). Block
      // only briefly on the console, then check the socket, so neither a
      // keystroke nor a packet waits on the other.
      const slice = ms === Infinity ? 40 : Math.min(ms, 40);
      if (con.readable(slice)) pushEvent(stdinSub);
      const ready = link.readable(0);
      if (ready === null) return ERRNO_INVAL;
      if (ready) pushEvent(connSub);
    } else if (stdinSub || (clockSub && timeout > 0)) {
      // Waiting for input doubles as the sleep: nothing else happens in
      // this thread while the guest is idle.
      if (con.readable(ms) && stdinSub) pushEvent(stdinSub);
    }
    if (clockSub) {
      const ev = new Event();
      ev.userdata = clockSub.userdata; ev.error = 0; ev.type = new EventType('clock');
      events.push(ev);
    }
    Event.write_bytes_array(view, out_ptr, events);
    view.setUint32(nevents_ptr, events.length, true);
    return 0;
  };
}

onmessage = async (e) => {
  const m = e.data;
  if (!m || m.t !== 'init') return;
  const con = new Console(m.sab);
  trace = !!m.trace;
  if (m.image === 'echo') {
    // No machine, just the console: what comes in goes back out, and a
    // quiet second prints a dot. Proves the plumbing without an image.
    postMessage({ t: 'ready' });
    for (;;) {
      if (!con.readable(1000)) {
        postMessage({ t: 'out', b: new TextEncoder().encode('.') });
        continue;
      }
      const bytes = con.read(4096);
      if (bytes) postMessage({ t: 'out', b: bytes }, [bytes.buffer]);
    }
  }
  try {
    const t0 = performance.now();
    // With a network: the stack's certificate first, so the guest can be
    // told to trust the proxy, then the socket the frames travel on.
    let link = null;
    let fds = [];
    let args = m.args || ['conterm'];
    let env = m.env || [];
    if (m.net) {
      link = new Link(m.net.sab);
      args = args.concat(['--net=socket=listenfd=' + LISTEN_FD, '--mac', m.net.mac]);
      if (m.net.mode === 'proxy') {
        // The proxy terminates TLS with its own certificate, so the guest
        // is told to trust it and to send its HTTP through it.
        const cert = await receiveCert(link);
        postMessage({ t: 'log', s: 'proxy certificate ' + cert.length + ' bytes' });
        fds = [undefined, undefined, undefined, certDir(cert)];
        env = env.concat([
          'SSL_CERT_FILE=/.wasmenv/proxy.crt',
          'CURL_CA_BUNDLE=/.wasmenv/proxy.crt',
          'GIT_SSL_CAINFO=/.wasmenv/proxy.crt',
          'REQUESTS_CA_BUNDLE=/.wasmenv/proxy.crt',
          'NODE_EXTRA_CA_CERTS=/.wasmenv/proxy.crt',
          'PIP_CERT=/.wasmenv/proxy.crt',
          'https_proxy=http://192.168.127.253:80',
          'http_proxy=http://192.168.127.253:80',
          'HTTPS_PROXY=http://192.168.127.253:80',
          'HTTP_PROXY=http://192.168.127.253:80',
          'no_proxy=localhost,127.0.0.1',
        ]);
      }
      // 'native': real sockets, so nothing to trust and no proxy to point
      // at; the guest talks straight to the world through the app's stack.
    }
    let module;
    try {
      module = await WebAssembly.compileStreaming(fetch(m.image));
    } catch (err) {
      postMessage({ t: 'log', s: 'streaming compile failed, buffering: ' + err });
      const resp = await fetch(m.image);
      if (!resp.ok) throw new Error('image ' + resp.status);
      module = await WebAssembly.compile(await resp.arrayBuffer());
    }
    postMessage({ t: 'log', s: 'image compiled in ' + Math.round(performance.now() - t0) + ' ms' });
    const wasi = new WASI(args, env, fds);
    wire(wasi, con, link);
    if (link) socketShim(wasi, link, LISTEN_FD, CONN_FD);
    const inst = await WebAssembly.instantiate(module, { wasi_snapshot_preview1: wasi.wasiImport });
    postMessage({ t: 'ready' });
    const code = wasi.start(inst);
    postMessage({ t: 'exit', code });
  } catch (err) {
    const detail = err && err.message
      ? err.message + (err.stack ? ' @ ' + String(err.stack).split('\n')[0] : '')
      : String(err);
    postMessage({ t: 'exit', code: -1, s: detail });
  }
};

// The proxy's certificate authority, read off the link once the stack has
// written it. Polled, since the stack needs a moment to make it.
function receiveCert(link) {
  return new Promise((resolve) => {
    let got = new Uint8Array(0);
    const step = () => {
      const status = link.call({ t: 'recv_cert', len: 4096 });
      if (status < 0) { setTimeout(step, 100); return; }
      const part = link.taken();
      const joined = new Uint8Array(got.length + part.length);
      joined.set(got, 0); joined.set(part, got.length);
      got = joined;
      if (status === 1 && part.length === 0) resolve(got); else setTimeout(step, 0);
    };
    step();
  });
}

// A directory with the certificate in it, mounted into the guest.
function certDir(cert) {
  const dir = new PreopenDirectory('/.wasmenv', { 'proxy.crt': new File(cert) });
  const _path_open = dir.path_open;
  dir.path_open = (...a) => {
    const ret = _path_open.apply(dir, a);
    if (ret.fd_obj != null) {
      const o = ret.fd_obj;
      // The emulator reads it with pread, which the shim's file lacks.
      o.fd_pread = (view8, iovs, offset) => {
        const was = o.file_pos;
        if (o.fd_seek(offset, WHENCE_SET).ret !== 0) return { ret: -1, nread: 0 };
        const r = o.fd_read(view8, iovs);
        if (o.fd_seek(was, WHENCE_SET).ret !== 0) return { ret: -1, nread: 0 };
        return r;
      };
    }
    return ret;
  };
  dir.dir.contents['.'] = dir.dir;
  return dir;
}
