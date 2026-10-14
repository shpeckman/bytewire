# src/bytewire/base64.cr
class Bytewire
  BASE64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".to_slice

  BASE64_PAIRS = Slice(UInt16).new(4096) do |value|
    pair = uninitialized UInt8[2]
    pair[0] = BASE64_CHARS[value >> 6]
    pair[1] = BASE64_CHARS[value & 63]
    pair.to_unsafe.as(Pointer(UInt16)).value
  end

  BASE64_VALUES = Bytes.new(256, 0xFF_u8).tap do |table|
    BASE64_CHARS.each_with_index { |char, index| table[char] = index.to_u8 }
  end

  BASE64_PADDING = 0x3D_u8

  def self.base64_chunks(data : Bytes, limit : Int32 = 4096, & : Bytes, Bool ->) : Nil
    step = limit // 4 * 3
    raise ArgumentError.new("base64 chunk limit must be at least 4, got #{limit}") if step < 3
    offset = 0
    total  = data.size
    while offset < total
      length = Math.min(step, total - offset)
      yield data[offset, length], offset + length < total
      offset += length
    end
  end

  @[AlwaysInline]
  def self.bound_base64(data : Bytes) : Int32
    (data.size + 2) // 3 * 4
  end

  @[AlwaysInline]
  def self.bound_base64(data : String) : Int32
    (data.bytesize + 2) // 3 * 4
  end

  def unsafe_base64(data : Bytes) : self
    guard(::Bytewire.bound_base64(data), "unsafe_base64")
    source = data.to_unsafe
    size   = data.size
    target = (@buf + @pos).as(Pointer(UInt16))
    i      = 0
    probe  = 1_u16
    little = pointerof(probe).as(Pointer(UInt8)).value == 1_u8
    while i + 8 <= size
      word  = (source + i).as(Pointer(UInt64)).value
      group = little ? word.byte_swap : word
      target[0] = BASE64_PAIRS.unsafe_fetch(group >> 52)
      target[1] = BASE64_PAIRS.unsafe_fetch((group >> 40) & 4095)
      target[2] = BASE64_PAIRS.unsafe_fetch((group >> 28) & 4095)
      target[3] = BASE64_PAIRS.unsafe_fetch((group >> 16) & 4095)
      target += 4
      i += 6
    end
    while i + 3 <= size
      b0 = source[i].to_u32
      b1 = source[i + 1].to_u32
      b2 = source[i + 2].to_u32
      target[0] = BASE64_PAIRS.unsafe_fetch((b0 << 4) | (b1 >> 4))
      target[1] = BASE64_PAIRS.unsafe_fetch(((b1 & 0x0F) << 8) | b2)
      target += 2
      i += 3
    end
    tail = target.as(Pointer(UInt8))
    case size - i
    when 1
      b0 = source[i].to_u32
      target[0] = BASE64_PAIRS.unsafe_fetch(b0 << 4)
      tail[2] = BASE64_PADDING
      tail[3] = BASE64_PADDING
      tail += 4
    when 2
      b0 = source[i].to_u32
      b1 = source[i + 1].to_u32
      target[0] = BASE64_PAIRS.unsafe_fetch((b0 << 4) | (b1 >> 4))
      tail[2] = BASE64_CHARS.unsafe_fetch((b1 & 0x0F) << 2)
      tail[3] = BASE64_PADDING
      tail += 4
    end
    @pos = (tail - @buf).to_i32!
    self
  end

  @[AlwaysInline]
  def unsafe_base64(data : String) : self
    unsafe_base64(data.to_slice)
  end

  @[AlwaysInline]
  def base64(data : Bytes) : self
    reserve(::Bytewire.bound_base64(data))
    unsafe_base64(data)
  end

  @[AlwaysInline]
  def base64(data : String) : self
    base64(data.to_slice)
  end

  @[AlwaysInline]
  def self.bound_decode64(data : Bytes) : Int32
    data.size // 4 * 3 + 3
  end

  @[AlwaysInline]
  def self.bound_decode64(data : String) : Int32
    data.bytesize // 4 * 3 + 3
  end

  def unsafe_decode64(data : Bytes) : self
    guard(::Bytewire.bound_decode64(data), "unsafe_decode64")
    source = data.to_unsafe
    size   = data.size
    while size > 0 && data.size - size < 2 && source[size - 1] == BASE64_PADDING
      size -= 1
    end
    target  = @buf + @pos
    invalid = 0_u32
    i       = 0
    while i + 4 <= size
      a = BASE64_VALUES.unsafe_fetch(source[i]).to_u32
      b = BASE64_VALUES.unsafe_fetch(source[i + 1]).to_u32
      c = BASE64_VALUES.unsafe_fetch(source[i + 2]).to_u32
      d = BASE64_VALUES.unsafe_fetch(source[i + 3]).to_u32
      invalid |= a | b | c | d
      group = (a << 18) | (b << 12) | (c << 6) | d
      target[0] = (group >> 16).to_u8!
      target[1] = (group >> 8).to_u8!
      target[2] = group.to_u8!
      target += 3
      i += 4
    end
    case size - i
    when 1
      invalid = 0xFF_u32
    when 2
      a = BASE64_VALUES.unsafe_fetch(source[i]).to_u32
      b = BASE64_VALUES.unsafe_fetch(source[i + 1]).to_u32
      invalid |= a | b
      target[0] = ((a << 2) | (b >> 4)).to_u8!
      target += 1
    when 3
      a = BASE64_VALUES.unsafe_fetch(source[i]).to_u32
      b = BASE64_VALUES.unsafe_fetch(source[i + 1]).to_u32
      c = BASE64_VALUES.unsafe_fetch(source[i + 2]).to_u32
      invalid |= a | b | c
      target[0] = ((a << 2) | (b >> 4)).to_u8!
      target[1] = ((b << 4) | (c >> 2)).to_u8!
      target += 2
    end
    raise ArgumentError.new("invalid base64 input") if invalid & 0xC0 != 0
    @pos = (target - @buf).to_i32!
    self
  end

  @[AlwaysInline]
  def unsafe_decode64(data : String) : self
    unsafe_decode64(data.to_slice)
  end

  @[AlwaysInline]
  def decode64(data : Bytes) : self
    reserve(::Bytewire.bound_decode64(data))
    unsafe_decode64(data)
  end

  @[AlwaysInline]
  def decode64(data : String) : self
    decode64(data.to_slice)
  end
end
