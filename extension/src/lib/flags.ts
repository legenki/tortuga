// Flags are emoji drawn with a bundled font (src/styles/flags.css): Windows has
// no flag emoji of its own. Twemoji, CC-BY 4.0 — see public/fonts/LICENSE.md.
// From Nomada's src/lib/flags.ts.

/** The flag emoji for an ISO 3166-1 alpha-2 code, or '' for anything else. */
export function flagEmoji(code: string | null | undefined): string {
  const c = (code ?? '').toUpperCase();
  return /^[A-Z]{2}$/.test(c) ? String.fromCodePoint(...[...c].map(ch => 0x1f1e6 + ch.charCodeAt(0) - 65)) : '';
}
