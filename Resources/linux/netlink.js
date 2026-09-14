// The shared-memory link a worker uses to talk to the page while it is
// inside the emulator: post a request, block until the page has answered
// into the buffer. Also the socket system calls the network stack and the
// machine both need, routed over that link.
//
// Adapted from container2wasm's examples/wasi-browser/htdocs/worker-util.js.
import { Iovec, Ciovec } from './shim/wasi_defs.js';

const ERRNO_INVAL = 28;
const ERRNO_AGAIN = 6;

export class Link {
  constructor(sab) {
    this.ctl = new Int32Array(sab, 0, 1);
    this.status = new Int32Array(sab, 4, 1);
    this.len = new Int32Array(sab, 8, 1);
    this.data = new Uint8Array(sab, 12);
  }
  // Post and wait. The page stores the answer and sets ctl to 1.
  call(msg, transfer) {
    Atomics.store(this.ctl, 0, 0);
    postMessage(msg, transfer || []);
    Atomics.wait(this.ctl, 0, 0);
    return this.status[0];
  }
  // Bytes the page put in the buffer for the last call.
  taken() { return this.data.slice(0, this.len[0]); }

  accept() { return this.call({ t: 'accept' }) >= 0 && this.data[0] === 1; }
  send(bytes) { return this.call({ t: 'send', buf: bytes }) >= 0; }
  recv(len) { return this.call({ t: 'recv', len }) < 0 ? null : this.taken(); }
  // True when bytes wait on the socket, or arrive within the timeout.
  readable(timeoutMs) {
    if (this.call({ t: 'recv-is-readable', timeoutMs }) < 0) return null;
    return this.data[0] === 1;
  }
}

// The socket fds of a WASI program: one it listens on, one it accepts.
export function socketShim(wasi, link, listenfd, connfd) {
  const imp = wasi.wasiImport;
  let connected = false;
  const mem = () => new Uint8Array(wasi.inst.exports.memory.buffer);
  const view = () => new DataView(wasi.inst.exports.memory.buffer);

  const _fd_close = imp.fd_close;
  imp.fd_close = (fd) => {
    if (fd === connfd) { connected = false; return 0; }
    return _fd_close.apply(imp, [fd]);
  };
  const _fd_read = imp.fd_read;
  imp.fd_read = (fd, iovs_ptr, iovs_len, nread_ptr) => {
    if (fd === connfd) return imp.sock_recv(fd, iovs_ptr, iovs_len, 0, nread_ptr, 0);
    return _fd_read.apply(imp, [fd, iovs_ptr, iovs_len, nread_ptr]);
  };
  const _fd_write = imp.fd_write;
  imp.fd_write = (fd, iovs_ptr, iovs_len, nwritten_ptr) => {
    if (fd === connfd) return imp.sock_send(fd, iovs_ptr, iovs_len, 0, nwritten_ptr);
    return _fd_write.apply(imp, [fd, iovs_ptr, iovs_len, nwritten_ptr]);
  };
  const _fd_fdstat_get = imp.fd_fdstat_get;
  imp.fd_fdstat_get = (fd, fdstat_ptr) => {
    if (fd === listenfd || (fd === connfd && connected)) {
      const v = view();
      v.setUint8(fdstat_ptr, 6);      // filetype: socket_stream
      v.setUint8(fdstat_ptr + 1, 2);  // fdflags: nonblock
      return 0;
    }
    return _fd_fdstat_get.apply(imp, [fd, fdstat_ptr]);
  };
  const _fd_prestat_get = imp.fd_prestat_get;
  imp.fd_prestat_get = (fd, prestat_ptr) => {
    // Claim both fds so the shim never hands them to opened files.
    if (fd === listenfd || fd === connfd) { view().setUint8(prestat_ptr, 1); return 0; }
    return _fd_prestat_get.apply(imp, [fd, prestat_ptr]);
  };
  imp.sock_accept = (fd, flags, fd_ptr) => {
    if (fd !== listenfd || connected) return ERRNO_INVAL;
    if (!link.accept()) return ERRNO_AGAIN;
    connected = true;
    view().setUint32(fd_ptr, connfd, true);
    return 0;
  };
  imp.sock_send = (fd, iovs_ptr, iovs_len, si_flags, nwritten_ptr) => {
    if (fd !== connfd) return ERRNO_INVAL;
    const iovecs = Ciovec.read_bytes_array(view(), iovs_ptr, iovs_len);
    let total = 0;
    for (const iov of iovecs) {
      if (iov.buf_len === 0) continue;
      const bytes = mem().slice(iov.buf, iov.buf + iov.buf_len);
      if (!link.send(bytes)) return ERRNO_INVAL;
      total += bytes.length;
    }
    view().setUint32(nwritten_ptr, total, true);
    return 0;
  };
  imp.sock_recv = (fd, iovs_ptr, iovs_len, ri_flags, nread_ptr, ro_flags_ptr) => {
    if (fd !== connfd) return ERRNO_INVAL;
    const ready = link.readable(0);
    if (ready === null) return ERRNO_INVAL;
    if (!ready) return ERRNO_AGAIN;
    const iovecs = Iovec.read_bytes_array(view(), iovs_ptr, iovs_len);
    let total = 0;
    for (const iov of iovecs) {
      if (iov.buf_len === 0) continue;
      const bytes = link.recv(iov.buf_len);
      if (bytes === null) return ERRNO_INVAL;
      mem().set(bytes, iov.buf);
      total += bytes.length;
      if (bytes.length < iov.buf_len) break;
    }
    view().setUint32(nread_ptr, total, true);
    return 0;
  };
  imp.sock_shutdown = (fd, how) => {
    if (fd === connfd) connected = false;
    return 0;
  };
}
