// Site entry — minimal client-side enhancements.
// Loaded once on every page; defers non-critical work via IntersectionObserver.

const nav = document.querySelector<HTMLElement>('[data-nav]');

if (nav) {
  const onScroll = () => {
    const scrolled = window.scrollY > 12;
    nav.dataset.scrolled = scrolled ? 'true' : 'false';
  };
  onScroll();
  window.addEventListener('scroll', onScroll, { passive: true });
}

// Scroll-reveal: tag elements with .reveal once they intersect.
const revealEls = document.querySelectorAll<HTMLElement>('.reveal');
if (revealEls.length) {
  const io = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          io.unobserve(entry.target);
        }
      });
    },
    { rootMargin: '0px 0px -10% 0px', threshold: 0.05 }
  );
  revealEls.forEach((el) => io.observe(el));
}

// Theme toggle.
const themeBtn = document.querySelector<HTMLButtonElement>('[data-theme-toggle]');
if (themeBtn) {
  themeBtn.addEventListener('click', () => {
    const current = document.documentElement.dataset.theme === 'light' ? 'light' : 'dark';
    const next = current === 'light' ? 'dark' : 'light';
    document.documentElement.dataset.theme = next;
    try {
      localStorage.setItem('gf-theme', next);
    } catch (_) {}
  });
}

// Smooth-scroll for in-page anchors (account for fixed nav height).
document.querySelectorAll<HTMLAnchorElement>('a[href^="#"]').forEach((a) => {
  const id = a.getAttribute('href')?.slice(1);
  if (!id) return;
  a.addEventListener('click', (e) => {
    const target = document.getElementById(id);
    if (!target) return;
    e.preventDefault();
    const offset = 64;
    const top = target.getBoundingClientRect().top + window.scrollY - offset;
    window.scrollTo({ top, behavior: 'smooth' });
  });
});

// CLI typewriter demo.
const cliRoot = document.querySelector<HTMLElement>('[data-cli]');
if (cliRoot) {
  const stream = cliRoot.querySelector<HTMLElement>('[data-cli-stream]');
  const tabs = cliRoot.querySelectorAll<HTMLButtonElement>('[data-cli-tab]');
  if (stream) {
    let cancelled = false;

    const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

    type Line = { kind: 'cmd' | 'out' | 'ok' | 'warn' | 'err' | 'meta'; text: string };

    const SCRIPTS: Record<string, Line[]> = {
      pubkey: [
        { kind: 'cmd', text: '$ greedyfind --pubkey 02c6047f...95c709ee5 --from 0 --to 1000000' },
        { kind: 'meta', text: 'greedyfind 0.1.0 · Apple M-series · Metal 3.0' },
        { kind: 'out', text: 'target   : x = 0xc6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5' },
        { kind: 'out', text: 'range    : [0, 1000000)   device : Apple M-series' },
        { kind: 'out', text: 'variants : 512   pruned : 509   threads : 32' },
        { kind: 'out', text: 'streaming…  j = 0x4a3f12' },
        { kind: 'out', text: 'streaming…  j = 0x8b9d0e' },
        { kind: 'ok', text: 'MATCH    j = 0  variant = +2   scalar = 0x0000…0002' },
        { kind: 'out', text: 'checkpoint → ./out/greedy-001/checkpoint.json' },
        { kind: 'meta', text: 'session completed · 0.42s · 2.37 Mkeys/s' },
      ],
      address: [
        { kind: 'cmd', text: '$ greedyfind --address 1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa --from 2^70 --to 2^71' },
        { kind: 'warn', text: '! address-mode GPU sweep lands in A40+. Running CPU fallback…' },
        { kind: 'out', text: 'range    : [0x400000000000000000, 0x800000000000000000)' },
        { kind: 'out', text: 'workers  : 8   throughput : ~180 keys/s' },
        { kind: 'meta', text: 'research-grade sweep · see docs/security.md' },
      ],
      resume: [
        { kind: 'cmd', text: '$ greedyfind --resume ./out/greedy-001/checkpoint.json' },
        { kind: 'out', text: 'checkpoint ✓ sha256 verified' },
        { kind: 'out', text: 'resuming from  j = 0x4a3f12   device : Apple M-series' },
        { kind: 'out', text: 'telemetry → ./out/greedy-001/events.ndjson' },
        { kind: 'ok', text: 'session attached · streaming…' },
      ],
    };

    const play = async (key: string) => {
      cancelled = true;
      await sleep(20);
      cancelled = false;
      const lines = SCRIPTS[key] || SCRIPTS.pubkey;
      // typewriter: progressive reveal
      stream.innerHTML = '';
      const cur = document.createElement('div');
      cur.className = 'cli__line';
      cur.innerHTML = '<span class="cli__cursor"></span>';
      stream.appendChild(cur);

      for (let i = 0; i < lines.length; i++) {
        if (cancelled) return;
        const line = lines[i];
        const row = document.createElement('div');
        row.className = 'cli__line';
        if (line.kind === 'cmd') {
          const p = document.createElement('span');
          p.className = 'cli__prompt';
          p.textContent = 'greedyfind ❯';
          const c = document.createElement('span');
          c.className = 'cli__cmd';
          row.appendChild(p);
          row.appendChild(c);
          stream.insertBefore(row, cur);
          for (const ch of line.text.replace(/^\$\s*/, '')) {
            if (cancelled) return;
            c.textContent += ch;
            await sleep(8 + Math.random() * 18);
          }
        } else {
          const span = document.createElement('span');
          span.className = `cli__${line.kind}`;
          row.appendChild(span);
          stream.insertBefore(row, cur);
          for (const ch of line.text) {
            if (cancelled) return;
            span.textContent += ch;
            await sleep(4 + Math.random() * 10);
          }
        }
        await sleep(60);
      }
    };

    tabs.forEach((t) => {
      t.addEventListener('click', () => {
        tabs.forEach((other) => other.classList.remove('is-active'));
        t.classList.add('is-active');
        const key = t.dataset.cliTab || 'pubkey';
        play(key);
      });
    });

    // initial play when visible
    const ioCli = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            play('pubkey');
            ioCli.disconnect();
          }
        });
      },
      { threshold: 0.2 }
    );
    ioCli.observe(cliRoot);
  }
}