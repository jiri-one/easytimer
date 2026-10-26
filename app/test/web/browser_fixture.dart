import 'dart:js_interop';

@JS('eval')
external JSAny? _evaluate(JSString source);

void script(String source) => _evaluate(source.toJS);

double number(String source) =>
    (_evaluate(source.toJS) as JSNumber).toDartDouble;

bool boolean(String source) => (_evaluate(source.toJS) as JSBoolean).toDart;

List<double> numbers(String source) =>
    (_evaluate(source.toJS) as JSArray<JSNumber>).toDart
        .map((value) => value.toDartDouble)
        .toList();

Future<void> flushBrowserPromises() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void installBrowserFixture() => script(r'''
(() => {
  const originalContext = globalThis.AudioContext;
  const originalWake = Object.getOwnPropertyDescriptor(navigator, 'wakeLock');
  const originalVisibility = Object.getOwnPropertyDescriptor(document, 'visibilityState');
  const fixture = globalThis.timerFixture = {
    starts: [], nodes: [], played: [], buffers: [], attempts: 0, failStarts: 0,
    failAttempt: -1, resumeCalls: 0, holdResume: false, failResume: false,
    wakeRequests: [], locks: [], visibility: 'visible',
    state(value) {
      this.context.state = value;
      this.context.onstatechange?.(new Event('statechange'));
    },
    visible(value) {
      this.visibility = value;
      document.dispatchEvent(new Event('visibilitychange'));
    },
    advance(time, deliverEnded = true) {
      if (this.context.state !== 'running') throw new Error('Audio is suspended');
      this.context.currentTime = time;
      for (const node of this.nodes) {
        if (node.when === null || node.ended || node.disconnected) continue;
        const until = Math.min(node.when + node.buffer.duration, node.stopAt);
        if (!node.rendered && time > node.when && until > node.when) {
          node.rendered = true;
          this.played.push(node);
        }
        if (deliverEnded && time >= until) {
          node.ended = true;
          node.onended?.(new Event('ended'));
        }
      }
    },
    resolveWake(index, holdRelease = false, failRelease = false) {
      const lock = {
        released: false, releaseCalls: 0,
        release() {
          this.releaseCalls++;
          if (failRelease) return Promise.reject(new Error('release failed'));
          if (holdRelease) return new Promise((resolve, reject) => {
            this.finishRelease = () => { this.released = true; resolve(); };
            this.failRelease = reject;
          });
          this.released = true;
          return Promise.resolve();
        }
      };
      this.locks[index] = lock;
      this.wakeRequests[index].resolve(lock);
    },
    restore() {
      globalThis.AudioContext = originalContext;
      if (originalWake) Object.defineProperty(navigator, 'wakeLock', originalWake);
      else delete navigator.wakeLock;
      if (originalVisibility) Object.defineProperty(document, 'visibilityState', originalVisibility);
      else delete document.visibilityState;
      delete globalThis.timerFixture;
    }
  };
  Object.defineProperty(document, 'visibilityState', {
    configurable: true, get() { return fixture.visibility; }
  });
  Object.defineProperty(navigator, 'wakeLock', {
    configurable: true,
    value: { request(type) {
      if (type !== 'screen') throw new Error('Unexpected wake lock type');
      return new Promise((resolve, reject) => fixture.wakeRequests.push({resolve, reject}));
    } }
  });
  globalThis.AudioContext = class {
    constructor() {
      fixture.context = this;
      this.state = 'running';
      this.currentTime = 0;
      this.destination = {};
      this.decoded = 0;
    }
    createGain() {
      return fixture.gain = {gain: {value: 1}, connect() {}};
    }
    decodeAudioData() {
      const buffer = ++this.decoded === 1
        ? {kind: 'alarm', duration: 3.2}
        : {kind: 'end', duration: 0.25};
      fixture.buffers.push(buffer);
      return Promise.resolve(buffer);
    }
    createBufferSource() {
      const node = {
        buffer: null, when: null, stopAt: Infinity, rendered: false,
        disconnected: false, ended: false, onended: null,
        connect(gain) { this.gain = gain; },
        disconnect() { this.disconnected = true; },
        start(time) {
          fixture.attempts++;
          if (fixture.failStarts > 0 || fixture.failAttempt === fixture.attempts) {
            fixture.failStarts = Math.max(0, fixture.failStarts - 1);
            throw new Error('start failed');
          }
          this.when = time;
          fixture.starts.push(this);
        },
        stop(time = fixture.context.currentTime) {
          if (this.when === null) throw new Error('not started');
          this.stopAt = time;
        }
      };
      fixture.nodes.push(node);
      return node;
    }
    resume() {
      fixture.resumeCalls++;
      if (fixture.failResume) return Promise.reject(new Error('gesture required'));
      if (fixture.holdResume) return new Promise(resolve => {
        fixture.resolveResume = () => { fixture.state('running'); resolve(); };
      });
      fixture.state('running');
      return Promise.resolve();
    }
    close() { this.state = 'closed'; return Promise.resolve(); }
  };
})();
''');
