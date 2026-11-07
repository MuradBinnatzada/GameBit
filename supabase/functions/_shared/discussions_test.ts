import { assertEquals } from 'jsr:@std/assert@1'
import { breaksChatRules } from './discussion_filter.ts'
import {
  countLinks,
  isRefusal,
  MAX_LINKS,
  parseDiscussionRequest,
  POST_MAX,
  refuseContent,
  THREAD_BODY_MAX,
  tidyBody,
  tidyTitle,
} from './discussions.ts'

// The refused words are written in two halves, so a search of the code for them
// finds only the filter.
const word = (...halves: string[]) => halves.join('')
const NIGGER = word('nig', 'ger')
const NIGGA = word('nig', 'ga')

Deno.test('the worst racial slurs are refused, in a sentence, in capitals and with an ending', () => {
  for (
    const text of [
      NIGGER,
      `you are a ${NIGGER}`,
      NIGGER.toUpperCase(),
      `${NIGGER}s`,
      NIGGA,
      `what up ${NIGGA.toUpperCase()}!`,
      `sand ${word('nig', 'ger')}`,
      word('sand', 'nig', 'ger'),
      word('wet', 'back'),
      word('towel', 'head'),
      word('pa', 'ki'),
      word('жи', 'ды'),
      word('чу', 'рка'),
      word('ха', 'чи'),
      word('ни', 'ггер'),
    ]
  ) {
    assertEquals(breaksChatRules(text), true, text)
  }
})

Deno.test('child sexual abuse phrases are refused', () => {
  for (
    const text of [
      word('child ', 'porn'),
      word('anyone selling kiddie ', 'porn?'),
      word('child', 'pornography'),
      word('c', 'sam'),
      word('rape of a little ', 'child'),
      word('molesting ', 'kids'),
      word('детская ', 'порнография'),
      word('порно с ', 'детьми'),
      word('насиловать ', 'детей'),
    ]
  ) {
    assertEquals(breaksChatRules(text), true, text)
  }
})

Deno.test('a word dressed up to get past is still refused', () => {
  for (
    const text of [
      NIGGER.split('').join('.'),
      NIGGER.split('').join(' '),
      NIGGER.split('').join('-'),
      NIGGER.replace('i', '1'),
      NIGGER.replace('e', '3'),
      NIGGER.replace('g', 'ɡ'),
      NIGGER.replace('i', 'í').replace('e', 'é'),
      `${NIGGER}`.replace(/g/g, 'gg'),
      NIGGER.replace('n', 'ｎ'),
      NIGGER.replace('i', '​i'),
      // A Cyrillic "а" and "е" in a Latin word.
      NIGGA.replace('a', 'а'),
      NIGGER.replace('e', 'е'),
      // A Latin "x" and "a" in a Russian word.
      word('ха', 'чи').replace('а', 'a'),
      word('чурк', 'а').replace('у', 'y'),
    ]
  ) {
    assertEquals(breaksChatRules(text), true, text)
  }
})

Deno.test('a word that only contains one, or means something else, is fine', () => {
  for (
    const text of [
      'He had a snigger at that.',
      'Pakistan and Pakistani players',
      'Niger and Nigeria are countries',
      'nigerian prince',
      'a chink in his armor',
      'Kike is a Spanish name',
      'the coon cat',
      'Scunthorpe, assassin, cocktail, classic, passage',
      'child abuse awareness month',
      'kids server on Minecraft',
      'a childhood porn-free internet',
      'raped my wallet buying that DLC',
      'Нигер — страна в Африке',
      'вкусный хачапури по-аджарски',
      'жидкость для зарядки',
      'жидкий металл',
      'Фильм про детство и порнографию рекламы',
      'Dark Souls 3 is brutal and I love it. Elden Ring > everything.',
      'Какую игру выбрать на вечер?',
      '',
    ]
  ) {
    assertEquals(breaksChatRules(text), false, text)
  }
})

Deno.test('ordinary swearing is not the filter\'s business', () => {
  assertEquals(breaksChatRules('this boss is complete bullshit, what the fuck'), false)
  assertEquals(breaksChatRules('это просто пиздец, а не босс'), false)
})

Deno.test('a very long text is checked quickly', () => {
  const started = performance.now()
  breaksChatRules('n '.repeat(1500))
  breaksChatRules('n'.repeat(3000))
  breaksChatRules('g'.repeat(3000))
  breaksChatRules(`${'ni '.repeat(1000)}g`)
  assertEquals(performance.now() - started < 1000, true)
})

Deno.test('a title is one line without control or invisible characters', () => {
  assertEquals(tidyTitle('  Best   soulslike?\n\t '), 'Best soulslike?')
  assertEquals(tidyTitle('a\u0000b‮c​d'), 'a b c d')
  assertEquals(tidyTitle(12), '')
  assertEquals(tidyTitle(undefined), '')
})

Deno.test('a text keeps its line breaks, at most one empty line in a row', () => {
  assertEquals(tidyBody('One  line \r\n\r\n\r\n\r\nNext\t line\n  indented  '), 'One line\n\nNext line\nindented')
  assertEquals(tidyBody('a\u0000b'), 'a b')
  assertEquals(tidyBody('   '), '')
  assertEquals(tidyBody(null), '')
})

Deno.test('links are counted', () => {
  assertEquals(countLinks('no links here'), 0)
  assertEquals(countLinks('http://a.com and https://b.com and www.c.com'), 3)
})

Deno.test('a thread request has a board, a title, a text and maybe a game', () => {
  const game = '8d9cbd3e-3a0a-4d6e-8bb5-5a1c9b7b2f11'
  assertEquals(
    parseDiscussionRequest({ mode: 'thread', board: 'general', title: '  Hello   there ', body: 'First post.', game_id: game.toUpperCase() }),
    { mode: 'thread', board: 'general', title: 'Hello there', body: 'First post.', gameId: game },
  )
  assertEquals(
    parseDiscussionRequest({ mode: 'thread', board: 'off-topic', title: 'Hello', body: 'x' }),
    { mode: 'thread', board: 'off-topic', title: 'Hello', body: 'x', gameId: null },
  )
})

Deno.test('a thread request that is not right is refused with what is wrong', () => {
  const ok = { mode: 'thread', board: 'general', title: 'Hello', body: 'x' }
  for (
    const bad of [
      { ...ok, board: 'Not A Board' },
      { ...ok, board: undefined },
      { ...ok, title: 'ab' },
      { ...ok, title: 'x'.repeat(121) },
      { ...ok, title: '  \n ' },
      { ...ok, body: '' },
      { ...ok, body: 'x'.repeat(THREAD_BODY_MAX + 1) },
      { ...ok, game_id: 'not-a-uuid' },
      { ...ok, game_id: 5 },
    ]
  ) {
    const parsed = parseDiscussionRequest(bad)
    assertEquals(isRefusal(parsed) && parsed.code === 'BAD_REQUEST', true, JSON.stringify(bad))
  }
})

Deno.test('a reply has a thread and a text', () => {
  const thread = '8d9cbd3e-3a0a-4d6e-8bb5-5a1c9b7b2f11'
  assertEquals(parseDiscussionRequest({ mode: 'reply', thread, body: ' Thanks! ' }), { mode: 'reply', thread, body: 'Thanks!', replyTo: null })
  for (
    const bad of [
      { mode: 'reply', thread: 'x', body: 'hi' },
      { mode: 'reply', thread, body: '' },
      { mode: 'reply', thread, body: 'x'.repeat(POST_MAX + 1) },
      { mode: 'other' },
      null,
      undefined,
    ]
  ) {
    assertEquals(isRefusal(parseDiscussionRequest(bad)), true, JSON.stringify(bad))
  }
})

Deno.test('a reply may name the post it answers', () => {
  const thread = '8d9cbd3e-3a0a-4d6e-8bb5-5a1c9b7b2f11'
  const post = '0A1B2C3D-3a0a-4d6e-8bb5-5a1c9b7b2f22'
  assertEquals(parseDiscussionRequest({ mode: 'reply', thread, body: 'Agreed', reply_to: post }), {
    mode: 'reply',
    thread,
    body: 'Agreed',
    replyTo: post.toLowerCase(),
  })
  assertEquals(parseDiscussionRequest({ mode: 'reply', thread, body: 'Agreed', reply_to: null }), {
    mode: 'reply',
    thread,
    body: 'Agreed',
    replyTo: null,
  })
  for (const bad of ['x', 5, '', {}, [post]]) {
    const parsed = parseDiscussionRequest({ mode: 'reply', thread, body: 'Agreed', reply_to: bad })
    assertEquals(isRefusal(parsed) && parsed.code === 'BAD_REQUEST', true, JSON.stringify(bad))
  }
})

Deno.test('content is refused for the words, and for too many links', () => {
  assertEquals(refuseContent('A fine title', 'A fine text.'), null)
  assertEquals(refuseContent('A fine title', `you ${NIGGER}`)?.code, 'CONTENT_NOT_ALLOWED')
  assertEquals(refuseContent(NIGGER, 'A fine text.')?.code, 'CONTENT_NOT_ALLOWED')
  const links = Array.from({ length: MAX_LINKS + 1 }, (_, i) => `https://a.com/${i}`).join(' ')
  assertEquals(refuseContent('Title', links)?.code, 'TOO_MANY_LINKS')
  assertEquals(refuseContent('Title', links.split(' ').slice(0, MAX_LINKS).join(' ')), null)
})
