# src/bytewire/builder.cr
class Bytewire
  MAX_CAPACITY = Int32::MAX
  FLOAT_BOUND  = 32

  DIGIT_PAIRS = Bytes.new(256) do |i|
    number = i < 200 ? i // 2 : 0
    (i.even? ? number // 10 : number % 10).to_u8 + 48_u8
  end

  HEX_DIGITS = "0123456789abcdef".to_slice

  BILLION     =              1_000_000_000_u64
  TEN_POW_19  = 10_000_000_000_000_000_000_u64
  QUINTILLION =  1_000_000_000_000_000_000_u64

  alias Integer = Int8 | Int16 | Int32 | Int64 | UInt8 | UInt16 | UInt32 | UInt64
  alias Scalar = Integer | Int128 | UInt128 | Float32 | Float64 | Bool | Char | String | Bytes

  private macro fixed(max, signature, &block)
    @[AlwaysInline]
    def unsafe_{{signature.name}}({{signature.args.splat}}) : self
      guard({{max}}, {{"unsafe_#{signature.name}"}})
      {{block.body}}
      self
    end

    @[AlwaysInline]
    def {{signature.name}}({{signature.args.splat}}) : self
      reserve({{max}})
      unsafe_{{signature.name}}({{signature.args.map(&.var).splat}})
    end
  end

  private macro sized(signature, bound, &block)
    @[AlwaysInline]
    def self.bound_{{signature.name}}({{signature.args.splat}}) : Int32
      {{bound}}
    end

    @[AlwaysInline]
    def unsafe_{{signature.name}}({{signature.args.splat}}) : self
      guard(::Bytewire.bound_{{signature.name}}({{signature.args.map(&.var).splat}}), {{"unsafe_#{signature.name}"}})
      {{block.body}}
      self
    end

    @[AlwaysInline]
    def {{signature.name}}({{signature.args.splat}}) : self
      reserve(::Bytewire.bound_{{signature.name}}({{signature.args.map(&.var).splat}}))
      unsafe_{{signature.name}}({{signature.args.map(&.var).splat}})
    end
  end

  private macro value(type, bound, &block)
    @[AlwaysInline]
    def self.bound(value : {{type}}) : Int32
      {{bound}}
    end

    @[AlwaysInline]
    def unsafe_put(value : {{type}}) : self
      guard(::Bytewire.bound(value), "unsafe_put")
      {{block.body}}
      self
    end

    @[AlwaysInline]
    def put(value : {{type}}) : self
      reserve(::Bytewire.bound(value))
      unsafe_put(value)
    end
  end

  private macro fallback(method, result)
    @[AlwaysInline]
    def {{method}}(value : T) : {{result}} forall T
      \{% if T.union? %}
        case value
        \{% for type in T.union_types %}
          when \{{type}} then {{method}}(value)
        \{% end %}
        else raise "unreachable"
        end
      \{% else %}
        \{% raise "Bytewire cannot write a value of type #{T}: supported types are integers, floats, Bool, Char, String, Bytes and Nil. Convert it first, for example with #to_s." %}
      \{% end %}
    end
  end

  @buf : Pointer(UInt8)
  @pos : Int32
  @cap : Int32
  @io  : Sink?

  def initialize(capacity : Int32 = 4096)
    @cap = Math.max(capacity, 16)
    @buf = Pointer(UInt8).malloc(@cap)
    @pos = 0
    @io  = nil
  end

  @[AlwaysInline]
  def reset : Nil
    @pos = 0
  end

  @[AlwaysInline]
  def pos : Int32
    @pos
  end

  @[AlwaysInline]
  def capacity : Int32
    @cap
  end

  @[AlwaysInline]
  def remaining : Int32
    @cap - @pos
  end

  @[AlwaysInline]
  def empty? : Bool
    @pos == 0
  end

  @[AlwaysInline]
  def written : Bytes
    Slice.new(@buf, @pos)
  end

  @[AlwaysInline]
  def reserve(count : Int32) : self
    grow(count) if @cap - @pos < count
    self
  end

  def truncate(position : Int32) : self
    unless 0 <= position <= @pos
      raise ArgumentError.new("cannot truncate to #{position}: #{@pos} bytes written")
    end
    @pos = position
    self
  end

  def shrink(capacity : Int32 = 4096) : self
    target = Math.max(Math.max(capacity, @pos), 16)
    if target < @cap
      @buf = @buf.realloc(target)
      @cap = target
    end
    self
  end

  fixed 1, byte(value : UInt8) do
    @buf[@pos] = value
    @pos += 1
  end

  fixed 4, char(value : Char) do
    code = value.ord.to_u32!
    if code < 0x80
      @buf[@pos] = code.to_u8!
      @pos += 1
    else
      @pos += encode(code, @buf + @pos)
    end
  end

  fixed 11, int(value : Int8 | Int16 | Int32) do
    magnitude = value.to_u32!
    if value < 0
      @buf[@pos] = 45_u8
      @pos += 1
      magnitude = 0_u32 &- magnitude
    end
    digits32(magnitude)
  end

  fixed 10, int(value : UInt8 | UInt16 | UInt32) do
    digits32(value.to_u32!)
  end

  fixed 20, int(value : Int64) do
    magnitude = value.to_u64!
    if value < 0
      @buf[@pos] = 45_u8
      @pos += 1
      magnitude = 0_u64 &- magnitude
    end
    digits64(magnitude)
  end

  fixed 20, int(value : UInt64) do
    digits64(value)
  end

  fixed 40, int(value : Int128) do
    magnitude = value.to_u128!
    if value < 0
      @buf[@pos] = 45_u8
      @pos += 1
      magnitude = 0_u128 &- magnitude
    end
    digits128(magnitude)
  end

  fixed 39, int(value : UInt128) do
    digits128(value)
  end

  fixed 2, int2(value : Int32) do
    if value < 10
      @buf[@pos] = value.to_u8! &+ 48_u8
      @pos += 1
    else
      pair = (value &* 2) & 0xFE
      @buf[@pos] = DIGIT_PAIRS.unsafe_fetch(pair)
      @buf[@pos + 1] = DIGIT_PAIRS.unsafe_fetch(pair + 1)
      @pos += 2
    end
  end

  fixed 3, int3(value : Int32) do
    if value < 100
      unsafe_int2(value)
    else
      pair = (value % 100) * 2
      @buf[@pos] = (value // 100).to_u8! &+ 48_u8
      @buf[@pos + 1] = DIGIT_PAIRS.unsafe_fetch(pair)
      @buf[@pos + 2] = DIGIT_PAIRS.unsafe_fetch(pair + 1)
      @pos += 3
    end
  end

  fixed 2, hex2(value : UInt8) do
    @buf[@pos] = HEX_DIGITS.unsafe_fetch(value >> 4)
    @buf[@pos + 1] = HEX_DIGITS.unsafe_fetch(value & 0x0F)
    @pos += 2
  end

  fixed 16, hex(value : UInt8 | UInt16 | UInt32 | UInt64) do
    bits  = value.to_u64!
    count = bits == 0 ? 1 : (67 - bits.leading_zeros_count) // 4
    index = @pos + count
    count.times do
      index -= 1
      @buf[index] = HEX_DIGITS.unsafe_fetch(bits & 0x0F)
      bits >>= 4
    end
    @pos += count
  end

  fixed 2, csi do
    pair(0x1B_u8, 0x5B_u8)
  end

  fixed 2, apc do
    pair(0x1B_u8, 0x5F_u8)
  end

  fixed 2, dcs do
    pair(0x1B_u8, 0x50_u8)
  end

  fixed 2, st do
    pair(0x1B_u8, 0x5C_u8)
  end

  fixed 1, semi do
    @buf[@pos] = 0x3B_u8
    @pos += 1
  end

  sized bytes(value : Bytes), value.size do
    value.copy_to(@buf + @pos, value.size)
    @pos += value.size
  end

  @[AlwaysInline]
  def self.bound_bytes(value : StaticArray(UInt8, N)) : Int32 forall N
    N
  end

  @[AlwaysInline]
  def unsafe_bytes(value : StaticArray(UInt8, N)) : self forall N
    unsafe_bytes(value.to_slice)
  end

  @[AlwaysInline]
  def bytes(value : StaticArray(UInt8, N)) : self forall N
    bytes(value.to_slice)
  end

  sized str(value : String), value.bytesize do
    unsafe_bytes(value.to_slice)
  end

  sized repeat(value : UInt8, count : Int32), Math.max(count, 0) do
    if count > 0
      Slice.new(@buf + @pos, count).fill(value)
      @pos += count
    end
  end

  sized repeat(value : Char, count : Int32), Math.max(count, 0) * 4 do
    code = value.ord.to_u32!
    if code < 0x80
      unsafe_repeat(code.to_u8!, count)
    elsif count > 0
      first  = @buf + @pos
      length = encode(code, first)
      total  = length * count
      filled = length
      while filled < total
        step = Math.min(filled, total - filled)
        first.copy_to(first + filled, step)
        filled += step
      end
      @pos += total
    end
  end

  sized pad(value : Integer, width : Int32), Math.max(width, 0) + 21 do
    magnitude = value.to_u64!
    if value < 0
      @buf[@pos] = 45_u8
      @pos += 1
      magnitude = 0_u64 &- magnitude
    end
    start = @pos
    digits64(magnitude)
    length = @pos - start
    if length < width
      shift = width - length
      (@buf + start).move_to(@buf + start + shift, length)
      Slice.new(@buf + start, shift).fill(48_u8)
      @pos += shift
    end
  end

  value Int8 | Int16 | Int32, 11 do
    unsafe_int(value)
  end

  value UInt8, 3 do
    unsafe_int3(value.to_i32!)
  end

  value UInt16 | UInt32, 10 do
    unsafe_int(value)
  end

  value Int64 | UInt64, 20 do
    unsafe_int(value)
  end

  value Int128 | UInt128, 40 do
    unsafe_int(value)
  end

  value Char, 4 do
    unsafe_char(value)
  end

  value String, value.bytesize do
    unsafe_str(value)
  end

  value Bytes, value.size do
    unsafe_bytes(value)
  end

  value Bool, 5 do
    unsafe_str(value ? "true" : "false")
  end

  value Float32 | Float64, FLOAT_BOUND do
    start = @pos
    value.to_s(io)
    if @pos - start > FLOAT_BOUND
      raise ArgumentError.new("float text exceeded #{FLOAT_BOUND} bytes")
    end
  end

  value Nil, 0 do
  end

  fallback self.bound, Int32

  fallback unsafe_put, self

  fallback put, self

  @[AlwaysInline]
  def self.bound_field(prefix : String, value : Nil) : Int32
    0
  end

  @[AlwaysInline]
  def unsafe_field(prefix : String, value : Nil) : self
    self
  end

  @[AlwaysInline]
  def field(prefix : String, value : Nil) : self
    self
  end

  sized field(prefix : String, value : Scalar), prefix.bytesize + ::Bytewire.bound(value) do
    unsafe_str(prefix).unsafe_put(value)
  end

  sized osc(code : Int32), 14 do
    unsafe_byte(0x1B_u8).unsafe_byte(0x5D_u8).unsafe_int(code).unsafe_semi
  end

  sized osc(code : String), code.bytesize + 3 do
    unsafe_byte(0x1B_u8).unsafe_byte(0x5D_u8).unsafe_str(code).unsafe_semi
  end

  @[AlwaysInline]
  private def guard(count : Int32, name : String) : Nil
    {% unless flag?(:release) %}
      overrun(count, name) if count > @cap - @pos
    {% end %}
  end

  @[NoInline]
  private def overrun(count : Int32, name : String) : NoReturn
    raise IndexError.new("#{name} needs room for #{count} bytes but #{@cap - @pos} remain: call reserve first")
  end

  @[AlwaysInline]
  private def pair(first : UInt8, second : UInt8) : Nil
    @buf[@pos] = first
    @buf[@pos + 1] = second
    @pos += 2
  end

  @[AlwaysInline]
  private def encode(code : UInt32, target : Pointer(UInt8)) : Int32
    if code < 0x800
      target[0] = (0xC0_u32 | (code >> 6)).to_u8!
      target[1] = (0x80_u32 | (code & 0x3F)).to_u8!
      2
    elsif code < 0x10000
      target[0] = (0xE0_u32 | (code >> 12)).to_u8!
      target[1] = (0x80_u32 | ((code >> 6) & 0x3F)).to_u8!
      target[2] = (0x80_u32 | (code & 0x3F)).to_u8!
      3
    else
      target[0] = (0xF0_u32 | (code >> 18)).to_u8!
      target[1] = (0x80_u32 | ((code >> 12) & 0x3F)).to_u8!
      target[2] = (0x80_u32 | ((code >> 6) & 0x3F)).to_u8!
      target[3] = (0x80_u32 | (code & 0x3F)).to_u8!
      4
    end
  end

  @[AlwaysInline]
  private def digits32(value : UInt32) : Nil
    count = if value < 100
              value < 10 ? 1 : 2
            elsif value < 10_000
              value < 1_000 ? 3 : 4
            elsif value < 1_000_000
              value < 100_000 ? 5 : 6
            elsif value < 100_000_000
              value < 10_000_000 ? 7 : 8
            else
              value < 1_000_000_000 ? 9 : 10
            end
    index = @pos + count
    while value >= 100
      pair = (value % 100) * 2
      value //= 100
      index -= 2
      @buf[index] = DIGIT_PAIRS.unsafe_fetch(pair)
      @buf[index + 1] = DIGIT_PAIRS.unsafe_fetch(pair + 1)
    end
    if value >= 10
      pair = value * 2
      @buf[index - 2] = DIGIT_PAIRS.unsafe_fetch(pair)
      @buf[index - 1] = DIGIT_PAIRS.unsafe_fetch(pair + 1)
    else
      @buf[index - 1] = value.to_u8! + 48_u8
    end
    @pos += count
  end

  private def digits64(value : UInt64) : Nil
    if value <= UInt32::MAX
      digits32(value.to_u32!)
      return
    end
    high = value // BILLION
    low  = (value - high * BILLION).to_u32!
    if high >= BILLION
      top    = high // BILLION
      middle = (high - top * BILLION).to_u32!
      digits32(top.to_u32!)
      digits9(middle)
    else
      digits32(high.to_u32!)
    end
    digits9(low)
  end

  private def digits128(value : UInt128) : Nil
    if value <= UInt64::MAX
      digits64(value.to_u64!)
      return
    end
    high = value // TEN_POW_19
    low  = (value - high * TEN_POW_19).to_u64!
    digits128(high)
    lead = low // QUINTILLION
    rest = low - lead * QUINTILLION
    @buf[@pos] = lead.to_u8! + 48_u8
    @pos += 1
    digits9((rest // BILLION).to_u32!)
    digits9((rest % BILLION).to_u32!)
  end

  @[AlwaysInline]
  private def digits9(value : UInt32) : Nil
    upper  = value // 10_000
    lower  = value % 10_000
    lead   = upper // 10_000
    middle = upper % 10_000
    @buf[@pos] = lead.to_u8! + 48_u8
    digits4(@pos + 1, middle)
    digits4(@pos + 5, lower)
    @pos += 9
  end

  @[AlwaysInline]
  private def digits4(index : Int32, value : UInt32) : Nil
    first  = (value // 100) * 2
    second = (value % 100) * 2
    @buf[index] = DIGIT_PAIRS.unsafe_fetch(first)
    @buf[index + 1] = DIGIT_PAIRS.unsafe_fetch(first + 1)
    @buf[index + 2] = DIGIT_PAIRS.unsafe_fetch(second)
    @buf[index + 3] = DIGIT_PAIRS.unsafe_fetch(second + 1)
  end

  @[NoInline]
  private def grow(count : Int32) : Nil
    needed = @pos.to_i64 + count
    if needed > MAX_CAPACITY
      raise ArgumentError.new("Bytewire cannot hold #{needed} bytes: the limit is #{MAX_CAPACITY}")
    end
    capacity = @cap.to_i64
    while capacity < needed
      capacity *= 2
    end
    capacity = MAX_CAPACITY.to_i64 if capacity > MAX_CAPACITY
    @buf     = @buf.realloc(capacity.to_i32)
    @cap     = capacity.to_i32
  end
end
