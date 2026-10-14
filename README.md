# bytewire

A growable byte buffer for Crystal with allocation-free appends, a cursor for
reading bytes back, and templates that describe a byte sequence once and both
write and read it.

It is built for code that emits and parses a lot of small, structured byte
sequences, such as terminal escape codes:

```crystal
require "bytewire"

Bytewire.template Cursor, "\e[#{row : Int32};#{col : Int32}H"

b = Bytewire.new
b << Cursor.new(row: 12, col: 40)
STDOUT.write(b.written)

reader = Bytewire::Reader.new("\e[3;7H")
if cursor = Cursor.read?(reader)
  cursor.row # => 3
end
```

Writing a template reserves space once and allocates nothing. A template that
cannot be read back unambiguously does not compile.

## Contents

- [Installation](#installation)
- [The builder](#the-builder)
- [Templates](#templates)
- [Field types](#field-types)
- [What a declaration rejects](#what-a-declaration-rejects)
- [What writing rejects](#what-writing-rejects)
- [Writing your own format](#writing-your-own-format)
- [The reader](#the-reader)
- [Base64](#base64)
- [Using it as an IO](#using-it-as-an-io)
- [Limits](#limits)
- [Choosing an approach](#choosing-an-approach)
- [Development](#development)

## Installation

Add the shard to `shard.yml` and run `shards install`:

```yaml
dependencies:
  bytewire:
    github: shpeckman/bytewire
```

Crystal 1.21 or newer is required. The shard has no dependencies.

## The builder

`Bytewire` owns one buffer that doubles when it runs out of room.

```crystal
b = Bytewire.new        # 4096 bytes to start
b = Bytewire.new(64)    # or choose the initial capacity

b.csi.int(12).semi.int(40).char('H')
b.written               # => Bytes, a view of what has been appended
b.reset                 # forget the contents, keep the buffer
```

Every appender returns the builder, so calls chain. Chaining costs nothing:
the appenders are inlined and a chain compiles to the same code as separate
statements.

### State

Method                    | Result
--------------------------|--------------------------------------------------------------------------------------------------
`pos`                     | Number of bytes written.
`capacity`                | Size of the buffer.
`remaining`               | `capacity - pos`.
`empty?`                  | Whether nothing has been written.
`written`                 | The written bytes as a `Bytes` view.
`reset`                   | Sets `pos` to zero and keeps the buffer.
`truncate(position)`      | Rolls back to an earlier `pos`. Raises `ArgumentError` if `position` is negative or beyond `pos`.
`reserve(count)`          | Makes sure `count` more bytes fit, growing if needed.
`shrink(capacity = 4096)` | Reallocates down to `capacity`, or to `pos` if more is in use.
`io`                      | A write-only `IO` over the builder. See [Using it as an IO](#using-it-as-an-io).

`written` points into the buffer. An append that grows the buffer, and
`shrink`, both invalidate it, so take the slice after the last append.

### Appenders

Method                 | Writes
-----------------------|---------------------------------------------------------------------------------------------------------------------------
`byte(UInt8)`          | One byte.
`char(Char)`           | The character as UTF-8.
`str(String)`          | The string's bytes.
`bytes(Bytes)`         | The slice. A `StaticArray(UInt8, N)` is accepted too.
`int(value)`           | Any integer from `Int8` to `UInt128`, in decimal.
`int2(Int32)`          | A value from 0 to 99, without the general digit count.
`int3(Int32)`          | A value from 0 to 999, without the general digit count.
`hex(value)`           | An unsigned integer in lowercase hexadecimal, without leading zeros.
`hex2(UInt8)`          | Exactly two lowercase hexadecimal digits.
`pad(value, width)`    | An integer, left-padded with zeros to `width` digits. A minus sign is written before the padding.
`repeat(value, count)` | A byte or a character `count` times. A count of zero or less writes nothing.
`put(value)`           | Any supported value, chosen by its type: integers, floats, `Bool`, `Char`, `String`, `Bytes`, `Nil`. `nil` writes nothing.
`field(prefix, value)` | `prefix` followed by `value`, or nothing at all when `value` is `nil`.
`base64(data)`         | `Bytes` or a `String`, encoded with padding.
`decode64(data)`       | The bytes that `data` decodes to.
`<<(value)`            | A [template](#templates) value.
`csi`                  | `ESC [`
`osc(code)`            | `ESC ]`, the code (`Int32` or `String`), then `;`
`apc`                  | `ESC _`
`dcs`                  | `ESC P`
`st`                   | `ESC \`
`semi`                 | `;`

`int2` and `int3` trust their range. A value outside it writes wrong digits,
but never more than two or three bytes and never outside the buffer.

Passing `put` or `field` a type that is not supported is a compile error that
names the type.

### Checked and unchecked appends

The appenders above check capacity on every call. Each one except `<<` also
has an `unsafe_` twin that skips the check:

```crystal
b.reserve(3 * values.size)
values.each { |value| b.unsafe_int3(value) }
```

An `unsafe_` call needs room for the most that appender can write, which is
what its checked twin reserves: 11 bytes for `unsafe_int` of an `Int32`, the
string's size for `unsafe_str`, and so on. `Bytewire.bound(value)` and
`Bytewire.bound_<name>(arguments)` report that size where it depends on the
arguments.

- **Without `--release`**, every `unsafe_` call verifies that room and raises
  `IndexError` when it is missing, before writing anything. A reservation that
  is too small shows up in your specs.
- **With `--release`**, the check is compiled out and nothing protects you.

Templates use the unchecked appenders for you, so you rarely need to call
them directly.

## Templates

`Bytewire.template Name, "text"` declares a struct in the current
namespace. Each `#{name : Type}` in the text is a field.

```crystal
Bytewire.template Cursor, "\e[#{row : Int32};#{col : Int32}H"
Bytewire.template Color, "##{red : Bytewire::Hex2}#{green : Bytewire::Hex2}#{blue : Bytewire::Hex2}"
```

The struct has:

Member                        | What it does
------------------------------|----------------------------------------------------------------------------------------
`Name.new(field: value, ...)` | Builds a value. Arguments are named, never positional, so two fields cannot be swapped.
a getter per field            | Returns the field's value.
`Name.read?(reader)`          | Reads one value, or returns `nil` and leaves the reader where it was.
`Name.read(reader)`           | Reads one value, or raises `Bytewire::Reader::Error` carrying the position.
`Name.bound(value)`           | The most bytes the value can take when written.
`Name.unsafe_write(b, value)` | Writes without checking capacity. `b << value` is the checked form; prefer it.

Two values of a template are equal when their fields are.

**Writing** is `builder << value`. It works out the size, reserves once, and
writes the literal text and the fields straight into the buffer. It returns the
builder, so `b << first << second` chains.

**Reading** takes a `Bytewire::Reader`. It matches the literal text and
parses each field in order. It does not require the input to end where the
template does, so several values can be read one after another:

```crystal
reader = Bytewire::Reader.new(b.written)
while cursor = Cursor.read?(reader)
  # ...
end
```

The text must be a string literal in the source. A type used by a field must
be declared before the template that uses it.

## Field types

Type                              | Written as                                   | Read back as
----------------------------------|----------------------------------------------|---------------------------------------------------------------------
`Int8` to `Int128`, and unsigned  | Decimal, with `-` when negative.             | The same type. Leading zeros are accepted; overflow fails the read.
`Char`                            | UTF-8.                                       | One character. Malformed UTF-8 fails the read.
`String`                          | Its bytes.                                   | A new `String`, up to the text that follows the field.
`Bytes`                           | Its bytes.                                   | A view into the input, up to the text that follows the field.
`Bytewire::Hex(T)`                | Lowercase hexadecimal without leading zeros. | `T`, an unsigned integer up to `UInt64`. Either case is accepted.
`Bytewire::Hex2`                  | Exactly two lowercase hexadecimal digits.    | `UInt8`.
`Bytewire::Padded(T, N)`          | Decimal, zero-padded to at least `N` digits. | `T`, an integer up to 64 bits. Fewer than `N` digits fails the read.
`Bytewire::Base64(T)`             | Padded base64 of a `String` or `Bytes`.      | The decoded data, newly allocated.
another template                  | That template.                               | That template.
`Type?`                           | `Type`, or nothing when the value is `nil`.  | `nil` when `Type` does not match at that point.
`Bytewire::List(Item, Separator)` | The items with the separator between them.   | An `Array` of the item type. An empty list writes nothing.

The value a format type holds is its type argument: a `Hex(UInt32)` field is a
`UInt32`, and a `Padded(Int32, 4)` field is an `Int32`.

### Optional parts

Only a field can be optional, so to make literal text optional give it a
template of its own:

```crystal
Bytewire.template Columns, ",c=#{value : Int32}"
Bytewire.template Rows, ",r=#{value : Int32}"
Bytewire.template Place, "\e_Ga=p,i=#{id : Int32}#{columns : Columns?}#{rows : Rows?},z=#{layer : Int32}\e\\"

b << Place.new(id: 1, columns: Columns.new(value: 80), rows: nil, layer: 0)
# \e_Ga=p,i=1,c=80,z=0\e\\
```

### Lists

The separator is a template made only of literal text:

```crystal
Bytewire.template Semi, ";"
Bytewire.template Style, "\e[#{params : Bytewire::List(UInt8, Semi)}m"

b << Style.new(params: [1_u8, 38_u8, 255_u8]) # \e[1;38;255m
```

Items may be integers, `Char`, format types, templates, `String` or `Bytes`.

### Strings and where they end

A `String` or `Bytes` field has no length of its own. It is read up to the
literal text that follows it, or to the end of the input when it is the last
thing in the template. A template that ends with such a field takes its end
from wherever it is used:

```crystal
Bytewire.template Title, ";#{text : String}"
Bytewire.template Cell, "#{at : Cursor}#{title : Title?}\e\\"
```

Here a title is read up to `\e\\`.

A list of `String` or `Bytes` works the same way, and each item also ends at
the separator.

## What a declaration rejects

Each of these is a compile error that names the field:

- **A field that runs into what follows it.** Two numbers with nothing between
  them, a number followed by text that starts with a digit, or a number
  followed by a `Char` or a `String`.
- **A `String` or `Bytes` that nothing ends.** It must be followed by literal
  text or be last.
- **An optional field or a list that begins like what follows it.** Text that
  merely shares its first characters is fine, as `,c=` and `,r=` above. It is
  rejected when one begins with the whole of the other, as `,c` and `,c=`.
- **A separator that an item could swallow,** such as a list of integers
  separated by `0`.
- **An optional `String`, `Bytes` or `Base64`,** because a missing one cannot
  be told apart from an empty one. Give it a template that starts with literal
  text and make that optional.
- **A list whose items could be empty,** other than a list of `String` or
  `Bytes`.
- **A list whose items are templates ending in a `String` or `Bytes`.** Give
  the item template literal text at its end.
- **A format given a type it cannot encode,** such as `Hex(Int32)`.
- **A type with no encoding,** such as `Float64` or an `Array`.
- **A union other than `Type?`,** a field declared twice, a hole that is not
  `name : Type`, or a template with no text.

The checks compare what can come first: the leading literal text of a
template, or the characters a number or format can start with. They are
deliberately conservative, so a declaration that compiles can always be read
back.

## What writing rejects

Some conflicts depend on the values, so they are checked when writing. Each
raises `ArgumentError` before anything is written:

- **A `String` or `Bytes` that contains the text that ends it,** or that would
  make that text appear early. With `"#{text : String}''"`, the value `it'`
  is rejected.
- **A list item of `String` or `Bytes` that contains the first byte** of the
  separator or of the text that follows the list.
- **A list of `String` or `Bytes` holding exactly one empty item,** because it
  would be written the same as an empty list.

A value that writes without raising always reads back equal.

## Writing your own format

A format is a module with a `BYTE_SHAPE` constant and three class methods:

```crystal
module Percent
  BYTE_SHAPE = {first: "0123456789", more: "", value: UInt8}

  def self.bound(value : UInt8, before : Bytes? = nil) : Int32
    4
  end

  def self.unsafe_write(builder : Bytewire, value : UInt8) : Nil
    builder.unsafe_int3(value.to_i32).unsafe_byte(0x25_u8)
  end

  def self.read?(reader : Bytewire::Reader, before : Bytes? = nil) : UInt8?
    start = reader.pos
    value = reader.int?(UInt8)
    return value if value && reader.match?('%')
    reader.pos = start
    nil
  end
end

Bytewire.template Progress, "[#{done : Percent}]"
```

Key       | Meaning
----------|----------------------------------------------------------------------------------------------------------------------------
`first`   | The characters the written form can begin with, or `"*"` for any.
`more`    | The characters that would be taken as part of the value if they came right after it. Empty when the form marks its own end.
`value`   | The type a field holds: a type, or the position of one of the format's type arguments. Left out, it is the format itself.
`accepts` | Optional. A tuple of the types `value` may be; anything else is a compile error at the declaration.
`empty`   | Optional. `true` when the written form can be zero bytes.

The declaration checks rely on `first` and `more` being accurate.

- `bound` must never be smaller than what `unsafe_write` writes.
- `read?` must leave the reader where it was when it returns `nil`.
- `before` is the text that follows the field, when there is any. Only formats
  that read up to that text need it.

## The reader

`Bytewire::Reader` is a cursor over `Bytes` or a `String`. It is a class,
so passing it to a method shares the cursor.

```crystal
reader = Bytewire::Reader.new(input)
if reader.csi? && (row = reader.int?(Int32)) && reader.semi? && (col = reader.int?(Int32)) && reader.match?('R')
  # row and col are Int32 here
end
```

Every parser comes in two forms. The form ending in `?` returns `nil` (or
`false` for a matcher) and leaves the cursor where it was. The plain form
raises `Bytewire::Reader::Error`, whose `position` is the byte offset.

### State

Method        | Result
--------------|--------------------------------------------------------------------------
`pos`         | The cursor's byte offset.
`pos = n`     | Moves the cursor. Raises `ArgumentError` outside the input.
`size`        | Size of the input.
`remaining`   | `size - pos`.
`eof?`        | Whether the cursor is at the end.
`data`        | The whole input.
`rest`        | The input from the cursor on, without moving.
`peek?`       | The next byte without moving, or `nil` at the end.
`reset`       | Moves the cursor back to the start.
`reset(data)` | Points the reader at new `Bytes` or a new `String`, so one can be reused.

### Values

Method                     | Reads
---------------------------|--------------------------------------------------------------------------------------------
`byte`                     | One byte.
`char`                     | One UTF-8 character.
`int(type, width = 0)`     | A decimal integer of `type`. With a `width`, exactly that many digits.
`hex(type, width = 0)`     | A hexadecimal integer of an unsigned `type`, in either case.
`hex2`                     | Exactly two hexadecimal digits as a `UInt8`.
`read(type, before = nil)` | A value by type: an integer, `Char`, `String` or `Bytes`. The last two read up to `before`.

### Slices

These return views into the input and copy nothing.

Method                  | Takes
------------------------|-----------------------------------------------------------------------------------
`take(count)`           | Exactly `count` bytes.
`take_until(delimiter)` | Everything before a `UInt8`, `Bytes` or `String` delimiter, which is not consumed.
`take_while { }`        | Bytes while the block is true. Always succeeds, so it has no `?` form.
`take_rest`             | Everything left. Always succeeds.
`base64`                | The run of base64 characters and padding, still encoded. Always succeeds.

### Matchers

Method         | Matches
---------------|--------------------------------------------------
`match(value)` | A `UInt8`, `Char`, `String` or `Bytes`.
`csi`          | `ESC [`
`osc(code)`    | `ESC ]`, the code (`Int32` or `String`), then `;`
`apc`          | `ESC _`
`dcs`          | `ESC P`
`st`           | `ESC \`
`semi`         | `;`

## Base64

```crystal
b.base64(png_bytes)
b.decode64("aGVsbG8=")
```

- `base64` writes standard base64 with padding.
- `decode64` accepts padded or unpadded input. Invalid input raises
  `ArgumentError` and leaves the builder's position unchanged.
- `Bytewire.base64_chunks(data, limit = 4096) { |chunk, more| ... }` yields
  slices of the raw data sized so that each encodes to at most `limit`
  characters. `more` is `false` for the last one.

```crystal
Bytewire.template Chunk, "\e_Gm=#{more : UInt8};#{data : Bytewire::Base64(Bytes)}\e\\"

Bytewire.base64_chunks(image) do |chunk, more|
  b << Chunk.new(more: more ? 1_u8 : 0_u8, data: chunk)
end
```

## Using it as an IO

`b.io` returns a write-only `IO` that appends to the builder. Use it to hand
the builder to code that writes to an `IO`:

```crystal
value.to_s(b.io)
b.io << "pi=" << 3.14159
```

The adapter is created on first use and reused. Reading from it raises
`IO::Error`. Writes through it are checked appends, so they are safe but
slower than the builder's own methods.

## Limits

- **Size.** A builder holds at most 2 GiB (`Int32::MAX` bytes). Growing past that raises `ArgumentError`.
- **Not thread-safe.** Neither a builder nor a reader has any locking.
- **Templates are literals.** The text must be in the source. There is no way to load a template at run time.
- **No floats in templates.** The reader cannot parse them. `put` still writes them to a builder.
- **Reading can allocate.** A `String` field, a `Base64` field and a list each allocate when read. Integers, `Char`, `Bytes` and nested templates do not.
- **`Bytes` fields are views.** They are only valid while the input they were read from is.
- **Names.** A template includes `Bytewire::Template` and defines a `BYTE_SHAPE` constant. Generated code uses locals beginning with `__bb`.

## Choosing an approach

Need                                                   | Use
-------------------------------------------------------|------------------------------------------------------------
Both written and read, or shared across call sites     | `Bytewire.template`
Written in one place with a known shape                | Chained appenders: `b.csi.int(row).semi.int(col).char('H')`
Numbers in 0..99, 0..999, or a two-digit hex byte      | `int2`, `int3`, or `hex2` instead of `int` or `hex`
An optional value with a prefix (such as `,c=80`)      | `b.field(",c=", columns)`
The same byte or character repeated many times         | `b.repeat('─', 80)`
A tight loop of small writes whose total size you know | `b.reserve(bound)` once, then `unsafe_` appenders
Passing the buffer to code that expects an `IO`        | `value.to_s(b.io)`

### What each choice costs

Choice                                    | Capacity checks        | Other effects
------------------------------------------|------------------------|--------------------------------------------------------------------------------------------------------------------
Template                                  | One per `<<`.          | The value is a struct on the stack. `String`, `Bytes` and list fields with an end scan their bytes to check for it.
Chained appends                           | One per append.        | A possible call into the growth path on every append. Skips delimiter scanning on strings.
`reserve` then `unsafe_` appends          | One, at the `reserve`. | Verified outside `--release` only. A small gain over checked appends; `int2` and `int3` matter more than `unsafe_`.
`b.io`                                    | One per write.         | Each write is a virtual call. Use it only to reach code that needs an `IO`.
Interpolating into a `String`, then `str` | One.                   | Allocates the string and copies it.

Effects that apply whichever way you write:

- **Floats are dominated by formatting.** The builder gains little over an
  `IO` for them.
- **Growth copies the buffer.** Give `Bytewire.new` a capacity close to
  what you expect, and reuse one builder with `reset` instead of creating one
  per sequence.
- **`reset` keeps the memory, `shrink` gives it back.** After one unusually
  large write, call `shrink` if the builder is long-lived.
- **Reuse one reader** with `reset(data)` instead of creating one per input.

### Measuring

The shard includes benchmarks that compare these approaches with string
interpolation, `IO::Memory` and the standard library's `Base64`:

```
crystal run --release --no-debug bench/all.cr
```

- **Pin the run to one core** on a processor with both performance and
  efficiency cores, so the scheduler does not move it mid-measurement.
- **Compare rows within one run.** Two builds of identical code can place a
  small loop differently and shift its timing, so a modest difference between
  two builds is not evidence of a change.

## Development

```
crystal spec
```

The suite includes `spec/compile_spec.cr`, which compiles small programs and
checks the error messages the template macro produces. It needs the `crystal`
binary on the path, or its location in the `CRYSTAL` environment variable, and
adds several seconds to the run.

## License

MIT.