// supabase/functions/_shared/supabase.ts
//
// The one place the Edge Functions import supabase-js from, so the version is
// pinned once and bumped once (and `deno check supabase/functions/*/index.ts` in
// CI shows what a bump breaks). The functions run on Deno's built-in
// `Deno.serve`; there is no std library import left to age.

export { createClient, type SupabaseClient, type User } from 'jsr:@supabase/supabase-js@2.118.0'
