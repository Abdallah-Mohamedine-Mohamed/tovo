import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '');
  return {
    plugins: [react()],
    server: {
      port: 5173,
      // En développement, les appels au backend passent par ce relais : pour
      // le navigateur, ils restent sur localhost. Le backend n'a pas de CORS,
      // et un appel direct à Railway depuis localhost échouait en « Failed to
      // fetch » (dépôt des pharmacies de garde, 03/10).
      proxy: env.VITE_API_BASE_URL
        ? {
          '/backend': {
            target: env.VITE_API_BASE_URL.replace(/\/$/, ''),
            changeOrigin: true,
            rewrite: (chemin: string) => chemin.replace(/^\/backend/, ''),
          },
        }
        : undefined,
    },
  };
});
