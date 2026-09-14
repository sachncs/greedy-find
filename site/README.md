# greedy-find site

The product marketing site for [greedy-find](https://github.com/sachncs/greedy-find).

A static, Astro-built single-page experience — no server runtime, no JS framework runtime. Ships as
plain HTML + a small inline typewriter script for the CLI demo. Designed to be deployed to GitHub
Pages at `sachncs.github.io/greedy-find`.

## Stack

- **Astro 4** — static site generator, zero JS by default
- **TypeScript** — typed component props + the CLI demo
- **Hand-rolled CSS** — custom design system (no Tailwind, no UI kit)
- **System + JetBrains Mono fonts** — Apple SF Pro first, web fallback

## Develop

```bash
cd site
npm install
npm run dev      # http://localhost:4321
```

## Build

```bash
npm run build    # → site/dist/
npm run preview  # serve the build locally
```

The build output (`site/dist/`) is what GitHub Pages serves.

## Deploy

The `.github/workflows/pages.yml` workflow builds `site/` and deploys the output to GitHub Pages
on every push to `main` / `master`.

**One-time repo setting** (Settings → Pages → Source): set to **GitHub Actions**.

The workflow:

1. Installs Node 20, then `site/` dependencies.
2. Runs `npm run build` (which runs `astro check` then `astro build`).
3. Uploads `site/dist/` as a Pages artifact.
4. Deploys via `actions/deploy-pages@v4` to
   `https://<org>.github.io/<repo>/` (configured `base: '/greedy-find'` in
   `astro.config.mjs`).

No manual deploys, no committed `dist/`.

## Structure

```
site/
├── astro.config.mjs     # base path, build format
├── package.json
├── public/
│   └── favicon.svg      # served at /favicon.svg
└── src/
    ├── layouts/Base.astro
    ├── pages/index.astro
    ├── components/      # Nav, Hero, Features, Architecture, CLI, …
    ├── icons/           # inline SVG icon set
    ├── scripts/main.ts  # scroll reveal, theme toggle, CLI typewriter
    └── styles/global.css
```

## Design notes

- Dark theme by default, light via OS preference or a manual toggle (stored in `localStorage`).
- Apple-style type scale, generous spacing, restrained motion.
- No colors beyond an electric-blue accent, a warm highlight, and standard surface tones.
- Every section is content-first; the page reads top-to-bottom as a product narrative.