import { assertEquals } from 'jsr:@std/assert@1'
import { listedAppIds, listIsWhole } from './steam_unlisted.ts'

Deno.test('a list is whole when it has games and as many as Steam says', () => {
  assertEquals(listIsWhole(3, 3), true)
  assertEquals(listIsWhole(1, 1), true)
})

Deno.test('an empty list, or one of another length, is not read as the library', () => {
  assertEquals(listIsWhole(0, 0), false) // an empty library can't tell a library from a failure
  assertEquals(listIsWhole(2, 3), false) // cut short
  assertEquals(listIsWhole(3, 2), false)
})

Deno.test('a count Steam did not send, or sent as something else, is not trusted', () => {
  assertEquals(listIsWhole(3, undefined), false)
  assertEquals(listIsWhole(3, null), false)
  assertEquals(listIsWhole(3, '3'), false)
  assertEquals(listIsWhole(3, Number.NaN), false)
})

Deno.test('the app ids are the distinct positive whole numbers of the list', () => {
  assertEquals(
    listedAppIds([{ appid: 440 }, { appid: 570 }, { appid: 440 }, {}, { appid: 0 }, { appid: -5 }, { appid: 1.5 }, { appid: '730' }]),
    [440, 570],
  )
  assertEquals(listedAppIds([]), [])
})
