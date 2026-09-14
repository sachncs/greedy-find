import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://sachncs.github.io',
  base: '/greedy-find',
  output: 'static',
  trailingSlash: 'ignore',
  build: {
    format: 'directory',
    inlineStylesheets: 'auto',
  },
  compressHTML: true,
  prefetch: {
    prefetchAll: false,
    defaultStrategy: 'hover',
  },
  vite: {
    build: {
      cssCodeSplit: true,
      assetsInlineLimit: 4096,
    },
  },
});