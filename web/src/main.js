import { boot, registerSheetRenderer } from './app.js';
import { renderSheet } from './sheets.js';

registerSheetRenderer(renderSheet);
boot().catch((failure) => {
  document.getElementById('root').textContent = failure.message;
});

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./sw.js').catch(() => {
      // Offline support is a bonus; the app works without it.
    });
  });
}
