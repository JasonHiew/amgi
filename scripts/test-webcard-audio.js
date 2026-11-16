// Executes the JS that WebCardAudioBridge injects, against a fake DOM, and
// asserts the interception contract. Extracts the string from the Swift source
// so the test covers exactly what ships, not a copy.
const fs = require('fs');

const swift = fs.readFileSync(process.argv[2], 'utf8');
const match = swift.match(/static let source = """([\s\S]*?)"""/);
if (!match) {
  console.error('FAIL: could not extract script from Swift source');
  process.exit(1);
}
const script = match[1];

// --- minimal DOM -----------------------------------------------------------
const posted = [];
let nativePlayCalls = 0;
let nativePauseCalls = 0;

class HTMLMediaElement {
  constructor(src) {
    this.src = src;
    this.currentSrc = src;
    this.listeners = {};
  }
  play() { nativePlayCalls++; return Promise.resolve('native'); }
  pause() { nativePauseCalls++; }
  dispatchEvent(evt) {
    (this.listeners[evt.type] || []).forEach((fn) => fn(evt));
  }
  addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); }
}

const window = {
  webkit: {
    messageHandlers: {
      amgiPlayAudio: { postMessage: (m) => posted.push(['play', m]) },
      amgiStopAudio: { postMessage: () => posted.push(['stop', {}]) },
    },
  },
};

const sandbox = { HTMLMediaElement, window, Promise, console };
sandbox.window.window = window;
new Function('HTMLMediaElement', 'window', 'Promise', script)(HTMLMediaElement, window, Promise);

const results = [];
function check(name, cond, detail) {
  results.push({ name, ok: !!cond, detail });
}

// 1. asset-scheme audio is intercepted: no native play, one message, token 1
const assetEl = new HTMLMediaElement('amgi-asset://media/beep.m4a');
let seen = [];
assetEl.addEventListener('playing', () => seen.push('playing'));
assetEl.play();
check('asset play does not reach WebKit', nativePlayCalls === 0, `nativePlayCalls=${nativePlayCalls}`);
check('asset play posts to native', posted.length === 1 && posted[0][0] === 'play', JSON.stringify(posted));
check('posted src is the asset url', posted[0] && posted[0][1].src === 'amgi-asset://media/beep.m4a', JSON.stringify(posted[0]));
check('posted token is numeric 1', posted[0] && posted[0][1].token === 1, JSON.stringify(posted[0]));
check('page still sees playing event', seen.includes('playing'), JSON.stringify(seen));

// 2. finishing natively replays `ended` into the page exactly once
let ended = 0;
assetEl.addEventListener('ended', () => { ended++; });
window.__amgiNativeAudioEnded(1);
window.__amgiNativeAudioEnded(1);
check('ended dispatched once for the token', ended === 1, `ended=${ended}`);
check('ended for an unknown token is a no-op', (() => { window.__amgiNativeAudioEnded(99); return ended === 1; })(), `ended=${ended}`);

// 3. non-asset media is untouched
const remote = new HTMLMediaElement('https://example.com/x.mp3');
remote.play();
check('non-asset play reaches WebKit', nativePlayCalls === 1, `nativePlayCalls=${nativePlayCalls}`);

// 4. pause tells native to stop
const asset2 = new HTMLMediaElement('amgi-asset://media/other.m4a');
asset2.play();
asset2.pause();
check('pause posts stop', posted.some((p) => p[0] === 'stop'), JSON.stringify(posted));

// 5. when native cannot take the file, the page still plays it
const asset3 = new HTMLMediaElement('amgi-asset://media/missing.m4a');
const before = nativePlayCalls;
asset3.play();
const token3 = posted.filter((p) => p[0] === 'play').slice(-1)[0][1].token;
window.__amgiNativeAudioFallback(token3);
check('fallback plays in the page', nativePlayCalls === before + 1, `nativePlayCalls=${nativePlayCalls}`);
check('fallback is single-use', (() => { const n = nativePlayCalls; window.__amgiNativeAudioFallback(token3); return nativePlayCalls === n; })(), `nativePlayCalls=${nativePlayCalls}`);

// 6. the card's replay queue: one reused element whose `src` is reassigned per
//    item while `currentSrc` still points at the previous file — the shape of
//    replaySequential() in CardWebViewBridge.js. Word then sentence, in order.
const queuePlayer = new HTMLMediaElement('amgi-asset://media/word.m4a');
queuePlayer.currentSrc = 'amgi-asset://media/word.m4a'; // stays stale on purpose
const queue = ['amgi-asset://media/word.m4a', 'amgi-asset://media/sentence.m4a'];
const played = [];
let queueIndex = 0;

function playNextQueuedItem() {
  if (queueIndex >= queue.length) return;
  const src = queue[queueIndex++];
  const before = posted.length;
  queuePlayer.src = src;            // currentSrc deliberately not updated
  queuePlayer.play();
  played.push(posted[before][1].src);
}

queuePlayer.addEventListener('ended', playNextQueuedItem); // advances the queue
playNextQueuedItem();
const wordToken = posted[posted.length - 1][1].token;
window.__amgiNativeAudioEnded(wordToken);                  // native finished the word

check('queue plays word then sentence, in order',
  JSON.stringify(played) === JSON.stringify(queue), JSON.stringify(played));
check('queue never replays the previous item',
  played[0] !== played[1], JSON.stringify(played));

let failed = 0;
for (const r of results) {
  console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.name}${r.ok ? '' : '  -> ' + r.detail}`);
  if (!r.ok) failed++;
}
console.log(`\n${results.length - failed}/${results.length} passed`);
process.exit(failed === 0 ? 0 : 1);
