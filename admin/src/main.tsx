import React from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App';

const conteneur = document.getElementById('root');
if (!conteneur) throw new Error('Élément #root introuvable');

createRoot(conteneur).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
