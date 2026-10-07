import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// En desarrollo, /api y /socket.io se redirigen al backend local.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      '/api': 'http://localhost:8080',
      '/socket.io': { target: 'http://localhost:8080', ws: true },
    },
  },
  build: { outDir: '../backend/public', emptyOutDir: true },
});
