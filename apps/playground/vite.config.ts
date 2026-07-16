import { defineConfig } from 'vite';
import solid from 'vite-plugin-solid';

// Served under /playground/ (e.g. behind the ASP reverse proxy).
export default defineConfig({
  base: '/playground/',
  plugins: [solid()],
});
