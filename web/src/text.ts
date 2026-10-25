/** Strings measured and trimmed as the Lean backend does, for checks that mirror its own. */

/** Whether `s` is empty once its ASCII whitespace is trimmed, as Lean's `trimAscii.isEmpty`. */
export function blankAscii(s: string): boolean {
  return /^[ \t\r\n]*$/.test(s);
}

/** Characters as Lean counts them (`String.length`): code points, not UTF-16 units. */
export function charLength(s: string): number {
  let n = 0;
  for (const _ of s) n++;
  return n;
}

/** Bytes of UTF-8, as Lean's `String.utf8ByteSize`. */
export function utf8Bytes(s: string): number {
  return new TextEncoder().encode(s).length;
}