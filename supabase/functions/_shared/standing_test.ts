import { assertEquals } from 'jsr:@std/assert@1'
import { isSuspended } from './standing.ts'

const answering = (answer: { data?: unknown; error?: unknown }) => ({
  rpc: (_fn: string, _args?: Record<string, unknown>) =>
    Promise.resolve({ data: answer.data ?? null, error: answer.error ?? null }),
})

Deno.test('a suspended member is told apart', async () => {
  assertEquals(await isSuspended(answering({ data: true }), 'u1'), true)
  assertEquals(await isSuspended(answering({ data: false }), 'u1'), false)
})

Deno.test('it asks the database about that member', async () => {
  const calls: Array<[string, Record<string, unknown> | undefined]> = []
  await isSuspended({
    rpc: (fn, args) => {
      calls.push([fn, args])
      return Promise.resolve({ data: false, error: null })
    },
  }, 'u1')
  assertEquals(calls, [['is_member_suspended', { target: 'u1' }]])
})

Deno.test('a check that fails lets the member through', async () => {
  const quiet = console.error
  console.error = () => {}
  try {
    assertEquals(await isSuspended(answering({ error: new Error('down') }), 'u1'), false)
    assertEquals(
      await isSuspended({ rpc: () => Promise.reject(new Error('unreachable')) }, 'u1'),
      false,
    )
  } finally {
    console.error = quiet
  }
})
