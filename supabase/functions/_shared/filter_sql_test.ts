import { assertEquals } from 'jsr:@std/assert@1'
import { sqlPatterns } from './discussion_filter.ts'

// The database filters the other public text (reviews, bios, names, list titles)
// with the same patterns as the discussions function. They live in a migration, so
// this keeps the two from drifting apart: the newest migration that defines
// private.breaks_chat_rules must hold exactly what discussion_filter.ts makes. To
// change the filter, add a term there and put the new strings in a *new* migration
// that redefines the function (an applied migration is never edited). Run with
// `--allow-read=supabase/migrations`.
const MIGRATIONS = new URL('../../migrations/', import.meta.url)
const DEFINES = /create or replace function private\.breaks_chat_rules\(/i

async function newestFilterMigration(): Promise<{ name: string; sql: string }> {
  const names: string[] = []
  for await (const entry of Deno.readDir(MIGRATIONS)) {
    if (entry.isFile && entry.name.endsWith('.sql')) names.push(entry.name)
  }
  names.sort()
  let found: { name: string; sql: string } | null = null
  for (const name of names) {
    const sql = await Deno.readTextFile(new URL(name, MIGRATIONS))
    if (DEFINES.test(sql)) found = { name, sql }
  }
  if (!found) throw new Error('No migration defines private.breaks_chat_rules')
  return found
}

Deno.test('the database filter has the patterns of discussion_filter.ts', async () => {
  const { name, sql } = await newestFilterMigration()
  const { latin, cyrillic } = sqlPatterns()
  for (const [which, pattern] of [['latin', latin], ['cyrillic', cyrillic]] as const) {
    assertEquals(
      sql.includes(`$${'re'}$${pattern}$${'re'}$`),
      true,
      `${name} must hold this ${which} pattern between $re$ marks (put it in a new migration that redefines private.breaks_chat_rules):\n$re$${pattern}$re$`,
    )
  }
})
