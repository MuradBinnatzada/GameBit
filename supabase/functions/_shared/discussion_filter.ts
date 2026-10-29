// supabase/functions/_shared/discussion_filter.ts
//
// The discussions' word filter. It is deliberately minimal: it refuses only the
// worst, racial slurs and the words that go with child sexual abuse. Ordinary
// swearing, heated arguments and everything else are left to the members and to
// reports. A post it refuses is not posted at all (the app says it breaks the chat
// rules, never which word did).
//
// Matching is on whole words, so a word that merely contains one is fine
// ("snigger", "Pakistan", "Niger", "хачапури"). Spelling around the filter is met
// halfway: capitals, accents, zero-width characters, look-alike letters and digits
// (0 for o, @ for a, a Cyrillic "а" for a Latin one), stretched letters and one or
// two separators between letters ("n.i.g.g.e.r").
//
// To add a word, add a line to LATIN_TERMS or CYRILLIC_TERMS and an example to the
// test. Leave out anything with an ordinary meaning ("coon", "chink", "spic",
// "kike", "niger"): this must never refuse an innocent sentence.

/** Letters of other alphabets and phonetic forms that look like a Latin one. */
const LOOKALIKES: Record<string, string> = { 'ɡ': 'g', 'ɑ': 'a', 'ı': 'i', 'ο': 'o', 'α': 'a', 'ι': 'i' }

/** What may sit between two letters of a word that is spelled around the filter. */
const GAP = '[^\\p{L}\\p{N}]{0,2}'

/**
 * [letters] as a pattern: each letter may repeat, with a gap between letters. They
 * are folded the way the text is (see [plain]), so "й" is "и" and "ё" is "е" here too.
 */
function word(letters: string): string {
  return [...plain(letters)].map((c) => `${c}+`).join(GAP)
}

/** One of [options] (each a [word]). */
function any(...options: string[]): string {
  return `(?:${options.map(word).join('|')})`
}

/** [parts] one after another, with a gap between. */
function seq(...parts: string[]): string {
  return parts.join(GAP)
}

const optional = (pattern: string) => `(?:${pattern})?`

/**
 * Racial slurs, and child-abuse phrases, in Latin letters. Only what no ordinary
 * sentence needs. Digits and signs typed for a letter are read as that letter
 * first, so these are spelled with letters only.
 */
const LATIN_TERMS: readonly string[] = [
  // Racial slurs
  seq(optional(any('sand', 'jungle', 'porch', 'dune', 'tar')), word('nigg'), any('er', 'a', 'ah', 'az', 'uh'), 's*'),
  any('wetback', 'wetbacks', 'towelhead', 'towelheads', 'raghead', 'ragheads', 'zipperhead', 'zipperheads'),
  any('jigaboo', 'jigaboos', 'paki', 'pakis'),
  // Child sexual abuse
  seq(any('child', 'children', 'kid', 'kids', 'kiddie', 'kiddy', 'underage', 'preteen', 'toddler', 'toddlers'), any('porn', 'porno', 'pornography')),
  word('csam'),
  seq(any('rape', 'raping', 'molest', 'molesting'), optional(word('of')), optional(any('a', 'the')), optional(word('little')), any('child', 'children', 'kid', 'kids', 'toddler', 'toddlers')),
]

/** The same in Cyrillic letters. "Нигер" (the country) and "хачапури" (the dish) are not slurs. */
const CYRILLIC_TERMS: readonly string[] = [
  // Racial slurs
  seq(word('нигг'), any('ер', 'а'), optional(any('ы', 'ов', 'ам', 'ами', 'у', 'ом'))),
  seq(word('чурк'), any('а', 'и', 'у', 'е', 'ой', 'ам', 'ами', 'ах')),
  seq(word('хач'), optional(any('и', 'ей', 'ам', 'ами', 'ик', 'ика', 'иков'))),
  seq(word('жид'), optional(any('ы', 'ов', 'ам', 'ами', 'ах', 'овка', 'овня', 'овский'))),
  // Child sexual abuse
  seq(word('детск'), any('ое', 'ая', 'ую', 'ой', 'ие', 'их', 'им'), word('порн'), optional(any('о', 'ография', 'ографию', 'ографии'))),
  seq(word('порно'), word('с'), word('детьми')),
  seq(any('изнасиловать', 'изнасилование', 'насиловать'), any('ребенка', 'ребёнка', 'детей', 'малолетку', 'малолеток')),
]

/** [terms] as one pattern that matches a word on its own: no letter of [alphabet] right before or after it. */
function compile(terms: readonly string[], alphabet: string): RegExp {
  return new RegExp(`(?<![${alphabet}])(?:${terms.join('|')})(?![${alphabet}])`, 'u')
}

const LATIN = compile(LATIN_TERMS, 'a-z')
const CYRILLIC = compile(CYRILLIC_TERMS, 'а-яё')

/**
 * The same two patterns for the database, which filters the other public text
 * (reviews, bios, names, handles, list titles) with `private.breaks_chat_rules` in
 * 20261028235500_moderation_and_blocking.sql. PostgreSQL's regular expressions
 * have no `\p{L}`; everything else here is spelled the same in both. The migration
 * holds these exact strings, and filter_sql_test.ts fails when it doesn't: after
 * changing a term, paste the new strings in (the test prints them).
 */
export function sqlPatterns(): { latin: string; cyrillic: string } {
  const gap = (source: string) => source.replaceAll(GAP, '[^[:alnum:]]{0,2}')
  return { latin: gap(LATIN.source), cyrillic: gap(CYRILLIC.source) }
}

/** Cyrillic letters that look like Latin ones, so a Latin word typed with them is read as Latin. */
const CYRILLIC_TO_LATIN: Record<string, string> = {
  а: 'a', в: 'b', е: 'e', к: 'k', м: 'm', н: 'h', о: 'o', р: 'p', с: 'c', т: 't', у: 'y', х: 'x', і: 'i',
}
/** Latin letters that look like Cyrillic ones, so a Russian word typed with them is read as Russian. */
const LATIN_TO_CYRILLIC: Record<string, string> = {
  a: 'а', b: 'в', e: 'е', k: 'к', m: 'м', h: 'н', o: 'о', p: 'р', c: 'с', t: 'т', y: 'у', x: 'х', i: 'и',
  '3': 'з', '0': 'о', '@': 'а',
}
/** Digits and signs typed for a Latin letter. */
const LEET: Record<string, string> = { '0': 'o', '1': 'i', '3': 'e', '4': 'a', '5': 's', '7': 't', '@': 'a', '$': 's', '!': 'i' }

/** [text] lower case, without accents, invisible characters and look-alike forms. */
function plain(text: string): string {
  return [
    ...text
      .normalize('NFKD')
      .replace(/[\p{M}\p{Cf}]/gu, '')
      .toLowerCase(),
  ].map((ch) => LOOKALIKES[ch] ?? ch).join('')
}

/** A digit or sign between two letters is the letter it stands for ("n1gger"); anywhere else it is punctuation. */
function unleet(text: string): string {
  return text.replace(/(?<=\p{L})[0134578@$!](?=\p{L})/gu, (ch) => LEET[ch] ?? ch)
}

/**
 * Whether [text] has a word the chat rules refuse: a racial slur or a child-abuse
 * phrase, in Latin or Cyrillic letters, however it was dressed up.
 */
export function breaksChatRules(text: string): boolean {
  const base = unleet(plain(text))
  const latin = [...base].map((ch) => CYRILLIC_TO_LATIN[ch] ?? ch).join('')
  const cyrillic = [...base].map((ch) => LATIN_TO_CYRILLIC[ch] ?? ch).join('')
  return LATIN.test(latin) || CYRILLIC.test(cyrillic)
}
