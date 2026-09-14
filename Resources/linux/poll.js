// poll_oneoff's wire structures, which the shim does not expose.
// Adapted from container2wasm's wasi-browser example.
import { EVENTTYPE_CLOCK, EVENTTYPE_FD_READ, EVENTTYPE_FD_WRITE } from './shim/wasi_defs.js';

export class EventType {
  constructor(variant) { this.variant = variant; }
  static from_u8(data) {
    switch (data) {
      case EVENTTYPE_CLOCK: return new EventType('clock');
      case EVENTTYPE_FD_READ: return new EventType('fd_read');
      case EVENTTYPE_FD_WRITE: return new EventType('fd_write');
      default: throw new Error('invalid event type ' + data);
    }
  }
  to_u8() {
    switch (this.variant) {
      case 'clock': return EVENTTYPE_CLOCK;
      case 'fd_read': return EVENTTYPE_FD_READ;
      case 'fd_write': return EVENTTYPE_FD_WRITE;
      default: throw new Error('unreachable');
    }
  }
}

export class Event {
  write_bytes(view, ptr) {
    view.setBigUint64(ptr, this.userdata, true);
    view.setUint8(ptr + 8, this.error);
    view.setUint8(ptr + 9, 0);
    view.setUint8(ptr + 10, this.type.to_u8());
  }
  static write_bytes_array(view, ptr, events) {
    for (let i = 0; i < events.length; i++) events[i].write_bytes(view, ptr + 32 * i);
  }
}

class SubscriptionClock {
  static read_bytes(view, ptr) {
    const s = new SubscriptionClock();
    s.timeout = Number(view.getBigUint64(ptr + 8, true));
    return s;
  }
}

class SubscriptionFdReadWrite {
  static read_bytes(view, ptr) {
    const s = new SubscriptionFdReadWrite();
    s.fd = view.getUint32(ptr, true);
    return s;
  }
}

class SubscriptionU {
  static read_bytes(view, ptr) {
    const s = new SubscriptionU();
    s.tag = EventType.from_u8(view.getUint8(ptr));
    switch (s.tag.variant) {
      case 'clock': s.data = SubscriptionClock.read_bytes(view, ptr + 8); break;
      case 'fd_read': case 'fd_write': s.data = SubscriptionFdReadWrite.read_bytes(view, ptr + 8); break;
      default: throw new Error('unreachable');
    }
    return s;
  }
}

export class Subscription {
  static read_bytes(view, ptr) {
    const s = new Subscription();
    s.userdata = view.getBigUint64(ptr, true);
    s.u = SubscriptionU.read_bytes(view, ptr + 8);
    return s;
  }
  static read_bytes_array(view, ptr, len) {
    const out = [];
    for (let i = 0; i < len; i++) out.push(Subscription.read_bytes(view, ptr + 48 * i));
    return out;
  }
}
