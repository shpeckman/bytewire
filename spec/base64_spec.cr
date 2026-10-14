# spec/base64_spec.cr
require "./spec_helper"

describe "Bytewire base64" do
  it "matches the standard library encoder" do
    builder = Bytewire.new(16)
    100.times do |size|
      data = Bytes.new(size) { |i| (i * 37 + size).to_u8! }
      builder.reset
      builder.base64(data)
      text(builder).should eq(Base64.strict_encode(data))
    end
    random = Random.new(7)
    200.times do
      data = random.random_bytes(random.rand(600))
      builder.reset
      builder.str("ab").base64(data)
      text(builder).should eq("ab" + Base64.strict_encode(data))
    end
    builder.reset
    builder.base64("hello")
    text(builder).should eq("aGVsbG8=")
  end

  it "encodes at an odd buffer offset" do
    builder = Bytewire.new(16)
    data    = Bytes.new(100) { |i| (i * 3).to_u8! }
    builder.byte(0x2E_u8).base64(data).byte(0x2E_u8).base64(data[0, 7])
    text(builder).should eq(".#{Base64.strict_encode(data)}.#{Base64.strict_encode(data[0, 7])}")
  end

  it "yields chunks that each encode within the limit" do
    data = Bytes.new(7000) { |i| (i * 7).to_u8! }
    seen = [] of Tuple(Int32, Bool)
    Bytewire.base64_chunks(data) { |chunk, more| seen << {chunk.size, more} }
    seen.should eq([{3072, true}, {3072, true}, {856, false}])
    builder = Bytewire.new(16)
    sizes   = [] of Int32
    Bytewire.base64_chunks(data, 100) do |chunk, _|
      before = builder.pos
      builder.base64(chunk)
      sizes << builder.pos - before
    end
    sizes.max.should eq(100)
    text(builder).should eq(Base64.strict_encode(data))
    calls = 0
    Bytewire.base64_chunks(Bytes.empty) { |_, _| calls += 1 }
    calls.should eq(0)
    expect_raises(ArgumentError, "at least 4") { Bytewire.base64_chunks(data, 3) { |_, _| } }
  end

  it "decodes what it encodes" do
    builder = Bytewire.new(16)
    random  = Random.new(5)
    300.times do
      data = random.random_bytes(random.rand(500))
      builder.reset
      builder.decode64(Base64.strict_encode(data))
      builder.written.should eq(data)
      builder.reset
      builder.byte(0x2E_u8).decode64(Base64.strict_encode(data).rstrip('=').to_slice)
      builder.written[1..].should eq(data)
    end
  end

  it "decodes several chunks into one buffer" do
    builder = Bytewire.new(16)
    data    = Bytes.new(9000) { |i| (i * 11).to_u8! }
    Bytewire.base64_chunks(data, 4096) do |chunk, _|
      builder.decode64(Base64.strict_encode(chunk))
    end
    builder.written.should eq(data)
  end

  it "rejects invalid input without moving its position" do
    builder = Bytewire.new(16)
    builder.str("ok")
    ["a", "ab=c", "ab c", "abc\n", "aGVsbG8===", "====", "a===", "*GVs", "aGVs*", "aGVsbé"].each do |input|
      expect_raises(ArgumentError, "invalid base64") { builder.decode64(input) }
      text(builder).should eq("ok")
    end
    builder.decode64("").decode64("aGk=").decode64("aGk")
    text(builder).should eq("okhihi")
  end
end
