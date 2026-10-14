# spec/builder_spec.cr
require "./spec_helper"

describe Bytewire do
  it "keeps its position across chained appends" do
    builder = Bytewire.new
    builder.csi.int(38).semi.int(2).semi.int3(255).semi.int3(7).semi.int3(42).char('m')
    text(builder).should eq("\e[38;2;255;7;42m")
  end

  it "encodes integers of every width" do
    builder = Bytewire.new
    [0, 7, 10, 99, 100, 101, 999, 1000, 65535, 1234567, Int32::MAX, -1, -90, Int32::MIN].each do |n|
      builder.reset
      builder.int(n)
      text(builder).should eq(n.to_s)
    end
    builder.reset
    builder.int(UInt32::MAX).semi.int(UInt64::MAX).semi.int(Int64::MIN).semi.int(7_u8).semi.int(-128_i8)
    builder.semi.int(4294967296_i64).semi.int(-4294967295_i64).semi.int(10_000_000_000_u64)
    text(builder).should eq("#{UInt32::MAX};#{UInt64::MAX};#{Int64::MIN};7;-128;4294967296;-4294967295;10000000000")
  end

  it "encodes 64-bit integers around every chunk boundary" do
    builder = Bytewire.new
    edges = [UInt32::MAX.to_u64, UInt32::MAX.to_u64 + 1, 999_999_999_u64, 1_000_000_000_u64,
             1_000_000_001_u64, 9_999_999_999_u64, 999_999_999_999_999_999_u64,
             1_000_000_000_000_000_000_u64, 1_000_000_000_000_000_001_u64,
             10_000_000_000_000_000_000_u64, 10_000_000_090_000_000_005_u64, UInt64::MAX]
    edges.each do |n|
      builder.reset
      builder.int(n)
      text(builder).should eq(n.to_s)
    end
    random = Random.new(42)
    2000.times do
      n = random.next_u.to_u64 &* random.next_u.to_u64 >> random.rand(40)
      builder.reset
      builder.int(n).semi.int(n.to_i64!)
      text(builder).should eq("#{n};#{n.to_i64!}")
    end
  end

  it "encodes 128-bit integers" do
    builder = Bytewire.new(16)
    edges = [0_u128, UInt64::MAX.to_u128, UInt64::MAX.to_u128 + 1, 10_000_000_000_000_000_000_u128,
             99_999_999_999_999_999_999_u128, 100_000_000_000_000_000_000_u128,
             100_000_000_000_000_000_000_000_000_000_000_000_007_u128, UInt128::MAX]
    edges.each do |n|
      builder.reset
      builder.int(n)
      text(builder).should eq(n.to_s)
    end
    [Int128::MIN, Int128::MAX, -1_i128, -18_446_744_073_709_551_616_i128].each do |n|
      builder.reset
      builder.int(n).put(n)
      text(builder).should eq(n.to_s * 2)
    end
    random = Random.new(9)
    500.times do
      n = (random.next_u.to_u128 << 96) | (random.next_u.to_u128 << 64) | (random.next_u.to_u128 << 32) | random.next_u
      n >>= random.rand(100)
      builder.reset
      builder.int(n)
      text(builder).should eq(n.to_s)
    end
  end

  it "encodes the two and three digit fast paths" do
    builder = Bytewire.new
    100.times { |n| builder.int2(n).semi }
    text(builder).should eq((0...100).join { |n| "#{n};" })
    builder.reset
    256.times { |n| builder.int3(n).semi }
    text(builder).should eq((0...256).join { |n| "#{n};" })
  end

  it "stays inside its tables when the digit fast paths get out-of-range values" do
    builder = Bytewire.new(16)
    [100, 127, 128, 255, 1_000_000, Int32::MAX, -1, Int32::MIN].each do |n|
      before = builder.pos
      builder.int2(n)
      (builder.pos - before).should be <= 2
      before = builder.pos
      builder.int3(n)
      (builder.pos - before).should be <= 3
    end
  end

  it "encodes hexadecimal" do
    builder = Bytewire.new(16)
    builder.hex2(0_u8).hex2(0x0a_u8).hex2(0xff_u8).semi
    builder.hex(0_u8).semi.hex(0xf_u8).semi.hex(0x10_u16).semi.hex(0xdeadbeef_u32).semi.hex(UInt64::MAX).semi.hex(0x1000_u64)
    text(builder).should eq("000aff;0;f;10;deadbeef;ffffffffffffffff;1000")
    random = Random.new(3)
    500.times do
      n = random.next_u.to_u64 &* random.next_u >> random.rand(60)
      builder.reset
      builder.hex(n)
      text(builder).should eq(n.to_s(16))
    end
  end

  it "pads integers with zeros" do
    builder = Bytewire.new(16)
    builder.pad(7, 3).semi.pad(123, 3).semi.pad(1234, 3).semi.pad(-5, 4).semi.pad(0, 1).semi.pad(9, 0).semi.pad(9, -3)
    builder.semi.pad(42_u8, 5).semi.pad(UInt64::MAX, 25).semi.pad(Int64::MIN, 3)
    text(builder).should eq("007;123;1234;-0005;0;9;9;00042;0000018446744073709551615;-9223372036854775808")
  end

  it "repeats bytes and characters" do
    builder = Bytewire.new(16)
    builder.repeat(0x20_u8, 5).repeat('x', 3).repeat('─', 4).repeat('🎉', 3).repeat('é', 1).repeat('y', 0).repeat('z', -4).repeat(0x21_u8, -1)
    text(builder).should eq("     xxx────🎉🎉🎉é")
    builder.reset
    builder.repeat('─', 5000).repeat(0x2E_u8, 5000)
    text(builder).should eq("─" * 5000 + "." * 5000)
  end

  it "writes every character as utf-8" do
    builder = Bytewire.new(16)
    sample  = ['a', '\u007f', '\u0080', 'é', '߿', 'ࠀ', '漢', '￿', '\u{10000}', '🎉', '\u{10ffff}', '\0']
    sample.each { |char| builder.char(char) }
    text(builder).should eq(sample.join)
    builder.reset
    expected = String.build do |io|
      (0..0x10FFFF).step(97) do |code|
        next if 0xD800 <= code <= 0xDFFF
        builder.char(code.chr)
        io << code.chr
      end
    end
    text(builder).should eq(expected)
  end

  it "grows on every kind of append" do
    builder = Bytewire.new(16)
    2000.times { |n| builder.csi.int(n).semi.int3(n % 256).char('é').str("ab").bytes("cd".to_slice).st }
    text(builder).should eq((0...2000).join { |n| "\e[#{n};#{n % 256}éabcd\e\\" })
    builder.capacity.should be >= builder.pos
  end

  it "reserves explicit headroom for unchecked appends" do
    builder = Bytewire.new(16)
    builder.reserve(5000)
    5000.times { builder.unsafe_byte(0x79_u8) }
    text(builder).should eq("y" * 5000)
    builder.remaining.should eq(builder.capacity - 5000)
  end

  {% unless flag?(:release) %}
    it "raises when an unchecked append has no room outside release builds" do
      builder = Bytewire.new(16)
      builder.reserve(16)
      16.times { builder.unsafe_byte(0x78_u8) }
      expect_raises(IndexError, "unsafe_byte needs room for 1 bytes but 0 remain: call reserve first") { builder.unsafe_byte(0x78_u8) }
      builder.truncate(10)
      expect_raises(IndexError, "unsafe_int needs room for 11 bytes but 6 remain: call reserve first") { builder.unsafe_int(7) }
      expect_raises(IndexError, "unsafe_str needs room for 7 bytes but 6 remain: call reserve first") { builder.unsafe_str("seven77") }
      expect_raises(IndexError, "unsafe_put needs room for 20 bytes but 6 remain: call reserve first") { builder.unsafe_put(7_i64) }
      expect_raises(IndexError, "unsafe_base64 needs room for 8 bytes but 6 remain: call reserve first") { builder.unsafe_base64("abcd") }
      builder.unsafe_str("six666").pos.should eq(16)
      builder.capacity.should eq(16)
    end
  {% end %}

  it "refuses to grow past the capacity limit" do
    builder = Bytewire.new(16)
    builder.str("abc")
    expect_raises(ArgumentError, "the limit is #{Int32::MAX}") { builder.reserve(Int32::MAX) }
    expect_raises(ArgumentError, "the limit is") { builder.repeat(0x20_u8, Int32::MAX - 1) }
    text(builder).should eq("abc")
    builder.capacity.should eq(16)
  end

  it "truncates back to an earlier position" do
    builder = Bytewire.new(16)
    builder.str("keep")
    mark = builder.pos
    builder.str("discard this text")
    builder.truncate(mark).str("!")
    text(builder).should eq("keep!")
    expect_raises(ArgumentError) { builder.truncate(6) }
    expect_raises(ArgumentError) { builder.truncate(-1) }
  end

  it "shrinks its buffer on request" do
    builder = Bytewire.new(16)
    builder.str("x" * 100_000)
    builder.capacity.should be >= 100_000
    builder.reset
    builder.str("kept")
    builder.shrink(64)
    builder.capacity.should eq(64)
    text(builder).should eq("kept")
    builder.str("y" * 200)
    builder.shrink(32)
    builder.capacity.should eq(204)
    builder.shrink(100_000)
    builder.capacity.should eq(204)
    text(builder).should eq("kept" + "y" * 200)
  end

  it "resets without releasing its buffer" do
    builder = Bytewire.new(16)
    builder.str("x" * 100)
    capacity = builder.capacity
    builder.reset
    builder.empty?.should be_true
    builder.capacity.should eq(capacity)
  end

  it "writes prefixed fields and skips nil values" do
    builder = Bytewire.new(16)
    absent  = nil.as(Int32?)
    present = 4.as(Int32?)
    builder.str("a=p").field(",c=", present).field(",r=", absent).field(",t=", 's').field(",n=", "x")
    builder.field(",b=", "yz".to_slice).field(",u=", UInt64::MAX).field(",f=", 1.5).field(",o=", true)
    text(builder).should eq("a=p,c=4,t=s,n=x,b=yz,u=#{UInt64::MAX},f=1.5,o=true")
  end

  it "dispatches put on the value type" do
    builder = Bytewire.new(16)
    builder.put(12).put("s").put('c').put("b".to_slice).put(nil).put(3_u8).put(true).put(false)
    text(builder).should eq("12scb3truefalse")
    mixed = [1, "two", '3', nil, 4.5, false] of Int32 | String | Char | Nil | Float64 | Bool
    builder.reset
    mixed.each { |value| builder.put(value) }
    text(builder).should eq("1two34.5false")
  end

  it "writes floats without leaving their bound" do
    builder = Bytewire.new(16)
    values = [0.0, -0.0, 1.5, -2.25, 1e100, -1.7976931348623157e308, 2.2250738585072014e-308, 5e-324,
              0.1 + 0.2, 123456789012345.67, 0.000123456789012345, Float64::INFINITY, -Float64::INFINITY, Float64::NAN]
    values.each do |value|
      builder.reset
      builder.put(value)
      text(builder).should eq(value.to_s)
      builder.pos.should be <= Bytewire::FLOAT_BOUND
    end
    builder.reset
    builder.put(1.5_f32).put(Float32::MAX).put(Float32::MIN_POSITIVE)
    text(builder).should eq("#{1.5_f32}#{Float32::MAX}#{Float32::MIN_POSITIVE}")
    random = Random.new(11)
    2000.times do
      value = random.next_u.to_u64.<<(32).|(random.next_u).unsafe_as(Float64)
      builder.reset
      builder.put(value)
      text(builder).should eq(value.to_s)
      builder.pos.should be <= Bytewire::FLOAT_BOUND
    end
  end

  it "builds osc, apc, and dcs envelopes" do
    builder = Bytewire.new
    builder.osc(21).str("foreground=?").st
    builder.osc("_dnd_code").str("t=q").st
    builder.apc.char('G').st.dcs.st
    text(builder).should eq("\e]21;foreground=?\e\\\e]_dnd_code;t=q\e\\\e_G\e\\\eP\e\\")
  end

  it "exposes a write-only IO" do
    builder = Bytewire.new(16)
    io      = builder.io
    io << "pi=" << 3.14159 << ' ' << 42 << ' ' << :symbol
    io.write_byte(0x21_u8)
    io.printf("%05d", 7)
    {1, "two"}.to_s(io)
    text(builder).should eq(%(pi=3.14159 42 symbol!00007{1, "two"}))
    builder.io.should be(io)
    expect_raises(IO::Error, "write-only") { io.read_byte }
  end
end
