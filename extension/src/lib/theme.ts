// Light or dark: what the user picked on the settings page, or else the system's.
// The pick lives in localStorage, which the popup and the settings page share,
// so theme.js can read it synchronously and set data-theme before the first paint.

export type Theme = 'light' | 'dark';

export const THEME_KEY = 'tortuga-theme';
const SYSTEM_DARK = '(prefers-color-scheme: dark)';

/** The theme picked on the settings page, if any. */
export function chosenTheme(): Theme | null {
  try {
    const value = localStorage.getItem(THEME_KEY);
    return value === 'light' || value === 'dark' ? value : null;
  } catch {
    return null;
  }
}

export function themeFor(chosen: Theme | null, systemDark: boolean): Theme {
  return chosen ?? (systemDark ? 'dark' : 'light');
}

function applyTheme(): void {
  document.documentElement.dataset.theme = themeFor(chosenTheme(), matchMedia(SYSTEM_DARK).matches);
}

export function chooseTheme(theme: Theme): void {
  try { localStorage.setItem(THEME_KEY, theme); } catch { /* storage off: lasts while the page is open */ }
  document.documentElement.dataset.theme = theme;
}

/** Follow the system again. */
export function clearTheme(): void {
  try { localStorage.removeItem(THEME_KEY); } catch { /* nothing stored */ }
  applyTheme();
}

/** Set the theme now, then follow the system and picks made on another page. */
export function watchTheme(): void {
  applyTheme();
  matchMedia(SYSTEM_DARK).addEventListener('change', applyTheme);
  addEventListener('storage', e => { if (e.key === THEME_KEY) applyTheme(); });
}
