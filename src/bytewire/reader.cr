# src/bytewire/reader.cr
class Bytewire
  class Reader
    class Error < Exception
      getter position : Int32

      def initialize(expected : String, @position : Int32)
        super("expected #{expected} at byte #{@position}")
      end
    end

    HEX_VALUES = Bytes.new(256, 0xFF_u8).tap do |table|
      HEX_DIGITS.each_with_index { |char, index| table[char] = index.to_u8 }
      (0x41_u8..0x46_u8).each { |char| table[char] = char - 55_u8 }
    end

    private macro parser(signature, result, expected, &block)
      def {{signature.name}}?({{signature.args.splat}}) : {{result}}?
        {{block.body}}
      end

      @[AlwaysInline]
      def {{signature.name}}({{signature.args.splat}}) : {{result}}
        value = {{signature.name}}?({{signature.args.map(&.var).splat}})
        value.nil? ? fail({{expected}}) : value
      end
    end

    private macro matcher(signature, expected, &block)
      def {{signature.name}}?({{signature.args.splat}}) : Bool
        {{block.body}}
      end

      @[AlwaysInline]
      def {{signature.name}}({{signature.args.splat}}) : Nil
        fail({{expected}}) unless {{signature.name}}?({{signature.args.map(&.var).splat}})
      end
    end

    private macro typed(type, &block)
      @[AlwaysInline]
      def read?(type : {{type}}.class, before : Bytes? = nil) : {{type}}?
        {{block.body}}
      end
    end

    @buf  : Pointer(UInt8)
    @pos  : Int32
    @size : Int32

    def initialize(data : Bytes)
      @buf  = data.to_unsafe
      @size = data.size
      @pos  = 0
    end

    def self.new(data : String) : self
      new(data.to_slice)
    end

    def self.index(data : Bytes, pattern : Bytes) : Int32?
      return 0 if pattern.empty?
      first = pattern.unsafe_fetch(0)
      last  = data.size - pattern.size
      index = 0
      while index <= last
        offset = data[index, last - index + 1].index(first)
        return nil unless offset
        index += offset
        return index if (data.to_unsafe + index).memcmp(pattern.to_unsafe, pattern.size) == 0
        index += 1
      end
      nil
    end

    @[AlwaysInline]
    def pos : Int32
      @pos
    end

    def pos=(position : Int32) : Int32
      unless 0 <= position <= @size
        raise ArgumentError.new("cannot move to #{position}: the input has #{@size} bytes")
      end
      @pos = position
    end

    @[AlwaysInline]
    def size : Int32
      @size
    end

    @[AlwaysInline]
    def remaining : Int32
      @size - @pos
    end

    @[AlwaysInline]
    def eof? : Bool
      @pos == @size
    end

    @[AlwaysInline]
    def data : Bytes
      Slice.new(@buf, @size)
    end

    @[AlwaysInline]
    def rest : Bytes
      Slice.new(@buf + @pos, @size - @pos)
    end

    @[AlwaysInline]
    def reset : Nil
      @pos = 0
    end

    def reset(data : Bytes) : Nil
      @buf  = data.to_unsafe
      @size = data.size
      @pos  = 0
    end

    def reset(data : String) : Nil
      reset(data.to_slice)
    end

    @[AlwaysInline]
    def peek? : UInt8?
      @pos < @size ? @buf[@pos] : nil
    end

    parser byte, UInt8, "a byte" do
      return nil unless @pos < @size
      value = @buf[@pos]
      @pos += 1
      value
    end

    parser char, Char, "a UTF-8 character" do
      left = @size - @pos
      return nil if left < 1
      source = @buf + @pos
      first  = source[0].to_u32
      if first < 0x80
        @pos += 1
        return first.unsafe_chr
      end
      length = first < 0xE0 ? 2 : (first < 0xF0 ? 3 : 4)
      return nil if first < 0xC2 || first > 0xF4 || left < length
      code  = first & (0xFF_u32 >> (length + 1))
      index = 1
      while index < length
        unit = source[index].to_u32
        return nil unless unit & 0xC0 == 0x80
        code = (code << 6) | (unit & 0x3F)
        index += 1
      end
      return nil if length == 3 && (code < 0x800 || 0xD800 <= code <= 0xDFFF)
      return nil if length == 4 && !(0x10000 <= code <= 0x10FFFF)
      @pos += length
      code.unsafe_chr
    end

    {% for row in [{Int8, UInt64}, {Int16, UInt64}, {Int32, UInt64}, {Int64, UInt64}, {Int128, UInt128}, {UInt8, UInt64}, {UInt16, UInt64}, {UInt32, UInt64}, {UInt64, UInt64}, {UInt128, UInt128}] %}
      {% type = row[0] %}
      {% wide = row[1] %}
      parser int(type : {{type}}.class, width : Int32 = 0), {{type}}, "an integer" do
        index    = @pos
        limit    = {{wide}}.new!({{type}}::MAX)
        negative = false
        {% if type.resolve < Int::Signed %}
          if index < @size && @buf[index] == 45_u8
            negative = true
            limit &+= 1
            index += 1
          end
        {% end %}
        start = index
        stop  = width > 0 && width < @size - index ? index + width : @size
        cut   = limit // 10
        last  = limit % 10
        value = {{wide}}.new!(0)
        while index < stop
          digit = @buf[index] &- 48_u8
          break if digit > 9
          return nil if value > cut || (value == cut && digit > last)
          value = value &* 10 &+ digit
          index += 1
        end
        count = index - start
        return nil if count == 0 || (width > 0 && count != width)
        @pos = index
        {{type}}.new!(negative ? {{wide}}.new!(0) &- value : value)
      end

      typed {{type}} do
        int?(type)
      end
    {% end %}

    {% for type in [UInt8, UInt16, UInt32, UInt64] %}
      parser hex(type : {{type}}.class, width : Int32 = 0), {{type}}, "a hexadecimal integer" do
        index = @pos
        stop  = width > 0 && width < @size - index ? index + width : @size
        value = {{type}}.new!(0)
        while index < stop
          digit = HEX_VALUES.unsafe_fetch(@buf[index])
          break if digit > 15
          return nil if value >> (sizeof({{type}}) * 8 - 4) != 0
          value = (value << 4) | digit
          index += 1
        end
        count = index - @pos
        return nil if count == 0 || (width > 0 && count != width)
        @pos = index
        value
      end
    {% end %}

    parser hex2, UInt8, "two hexadecimal digits" do
      hex?(UInt8, 2)
    end

    parser take(count : Int32), Bytes, "#{count} byte(s)" do
      return nil unless 0 <= count <= @size - @pos
      value = Slice.new(@buf + @pos, count)
      @pos += count
      value
    end

    parser take_until(delimiter : UInt8), Bytes, "a terminating byte #{delimiter}" do
      index = rest.index(delimiter)
      index ? take?(index) : nil
    end

    parser take_until(delimiter : Bytes), Bytes, "a terminator" do
      index = Reader.index(rest, delimiter)
      index ? take?(index) : nil
    end

    parser take_until(delimiter : String), Bytes, "a terminating #{delimiter.inspect}" do
      take_until?(delimiter.to_slice)
    end

    def take_while(& : UInt8 -> Bool) : Bytes
      index = @pos
      while index < @size && (yield @buf[index])
        index += 1
      end
      value = Slice.new(@buf + @pos, index - @pos)
      @pos  = index
      value
    end

    def take_rest : Bytes
      value = rest
      @pos  = @size
      value
    end

    def base64 : Bytes
      index = @pos
      while index < @size && BASE64_VALUES.unsafe_fetch(@buf[index]) < 64
        index += 1
      end
      padding = 0
      while padding < 2 && index < @size && @buf[index] == BASE64_PADDING
        index += 1
        padding += 1
      end
      value = Slice.new(@buf + @pos, index - @pos)
      @pos  = index
      value
    end

    matcher match(value : UInt8), "byte #{value}" do
      return false unless @pos < @size && @buf[@pos] == value
      @pos += 1
      true
    end

    matcher match(value : Bytes), "the bytes #{value.hexstring}" do
      length = value.size
      return false unless length <= @size - @pos && (@buf + @pos).memcmp(value.to_unsafe, length) == 0
      @pos += length
      true
    end

    matcher match(value : String), value.inspect do
      match?(value.to_slice)
    end

    matcher match(value : Char), value.inspect do
      index = @pos
      value.each_byte do |byte|
        return false unless index < @size && @buf[index] == byte
        index += 1
      end
      @pos = index
      true
    end

    {% for name, second in {csi: 0x5B, apc: 0x5F, dcs: 0x50, st: 0x5C} %}
      matcher {{name.id}}, {{name.stringify.upcase}} do
        return false unless @size - @pos >= 2 && @buf[@pos] == 0x1B_u8 && @buf[@pos + 1] == {{second}}_u8
        @pos += 2
        true
      end
    {% end %}

    matcher semi, "';'" do
      match?(0x3B_u8)
    end

    matcher osc(code : Int32), "OSC #{code}" do
      start = @pos
      return true if match?("\e]") && int?(Int32) == code && semi?
      @pos = start
      false
    end

    matcher osc(code : String), "OSC #{code}" do
      start = @pos
      return true if match?("\e]") && match?(code) && semi?
      @pos = start
      false
    end

    typed Char do
      char?
    end

    typed Bytes do
      before ? take_until?(before) : take_rest
    end

    typed String do
      value = read?(Bytes, before)
      value ? String.new(value) : nil
    end

    @[AlwaysInline]
    def read?(type : T.class, before : Bytes? = nil) : NoReturn forall T
      {% raise "Bytewire::Reader cannot read a value of type #{T}: supported types are integers, Char, String and Bytes." %}
    end

    @[AlwaysInline]
    def read(type : T.class, before : Bytes? = nil) : T forall T
      value = read?(type, before)
      value.nil? ? fail("a value of type #{T}") : value
    end

    private def fail(expected : String) : NoReturn
      raise Error.new(expected, @pos)
    end
  end
end
