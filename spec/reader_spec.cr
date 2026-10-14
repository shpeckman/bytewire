# spec/reader_spec.cr
require "./spec_helper"

private def reader(source : String) : Bytewire::Reader
  Bytewire::Reader.new(source)
end

describe Bytewire::Reader do
  it "tracks its position" do
    r = Bytewire::Reader.new("abc".to_slice)
    r.size.should eq(3)
    r.remaining.should eq(3)
    r.eof?.should be_false
    r.peek?.should eq(0x61_u8)
    r.byte.should eq(0x61_u8)
    r.pos.should eq(1)
    String.new(r.rest).should eq("bc")
    String.new(r.data).should eq("abc")
    r.pos = 3
    r.eof?.should be_true
    r.peek?.should be_nil
    r.byte?.should be_nil
    r.reset
    r.pos.should eq(0)
    expect_raises(ArgumentError, "cannot move to 4: the input has 3 bytes") { r.pos = 4 }
  end

  it "is shared by reference and can be pointed at new input" do
    r       = reader("12;34")
    advance = ->(shared : Bytewire::Reader) { shared.int(Int32) }
    advance.call(r).should eq(12)
    r.pos.should eq(2)
    r.reset("7")
    r.size.should eq(1)
    r.int(Int32).should eq(7)
    r.reset("89".to_slice)
    r.int(Int32).should eq(89)
    r.eof?.should be_true
  end

  it "reads UTF-8 characters and rejects malformed ones" do
    r = reader("aé€😀")
    r.char.should eq('a')
    r.char.should eq('é')
    r.char.should eq('€')
    r.char.should eq('😀')
    r.char?.should be_nil
    [Bytes[0x80], Bytes[0xC0, 0x80], Bytes[0xE2, 0x82], Bytes[0xED, 0xA0, 0x80], Bytes[0xF4, 0x90, 0x80, 0x80], Bytes[0xE0, 0x80, 0x80], Bytes[0xC3, 0x41]].each do |bad|
      r = Bytewire::Reader.new(bad)
      r.char?.should be_nil
      r.pos.should eq(0)
    end
  end

  it "reads integers of every width up to their limits" do
    {% for type in [Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128] %}
      r = reader("#{{{type}}::MAX} #{{{type}}::MIN} 007x")
      r.int({{type}}).should eq({{type}}::MAX)
      r.match(' ')
      r.int({{type}}).should eq({{type}}::MIN)
      r.match(' ')
      r.int({{type}}).should eq({{type}}.new(7))
      r.int?({{type}}).should be_nil
      r.pos.should eq(r.size - 1)
    {% end %}
  end

  it "rejects integers that overflow and leaves the cursor in place" do
    {"128" => Int8, "-129" => Int8, "256" => UInt8, "2147483648" => Int32, "18446744073709551616" => UInt64}.each do |source, type|
      r = reader(source)
      case type
      when Int8.class   then r.int?(Int8).should be_nil
      when UInt8.class  then r.int?(UInt8).should be_nil
      when Int32.class  then r.int?(Int32).should be_nil
      when UInt64.class then r.int?(UInt64).should be_nil
      end
      r.pos.should eq(0)
    end
    r = reader("-5")
    r.int?(UInt32).should be_nil
    r = reader("-")
    r.int?(Int32).should be_nil
    r.pos.should eq(0)
  end

  it "reads fixed-width integers" do
    r = reader("20261005-0042")
    r.int(Int32, 4).should eq(2026)
    r.int(Int32, 2).should eq(10)
    r.int(Int32, 2).should eq(5)
    r.int(Int32, 4).should eq(-42)
    r = reader("12x")
    r.int?(Int32, 3).should be_nil
    r.pos.should eq(0)
  end

  it "reads hexadecimal integers in either case" do
    r = reader("beef,FFFFFFFFFFFFFFFF,0a,100,g")
    r.hex(UInt16).should eq(0xbeef_u16)
    r.semi?.should be_false
    r.match(',')
    r.hex(UInt64).should eq(UInt64::MAX)
    r.match(',')
    r.hex2.should eq(0x0a_u8)
    r.match(',')
    r.hex?(UInt8).should be_nil
    r.hex(UInt8, 2).should eq(0x10_u8)
    r.match("0,")
    r.hex?(UInt32).should be_nil
    r.hex2?.should be_nil
  end

  it "takes slices of the input without copying" do
    source = "key=value\e\\tail"
    r      = reader(source)
    key    = r.take_until(0x3D_u8)
    String.new(key).should eq("key")
    key.to_unsafe.should eq(source.to_unsafe)
    r.take?(99).should be_nil
    r.take?(-1).should be_nil
    String.new(r.take(1)).should eq("=")
    String.new(r.take_until("\e\\")).should eq("value")
    r.take_until?("missing").should be_nil
    r.take_until?(0x00_u8).should be_nil
    r.st
    String.new(r.take_while { |byte| byte != 0x69_u8 }).should eq("ta")
    String.new(r.take_until("il".to_slice)).should eq("")
    String.new(r.take_rest).should eq("il")
    r.take_rest.empty?.should be_true
  end

  it "matches literal text and advances only on success" do
    r = reader("abc€d")
    r.match?("abd").should be_false
    r.pos.should eq(0)
    r.match?("ab").should be_true
    r.match?('€').should be_false
    r.match?(0x63_u8).should be_true
    r.match?('€').should be_true
    r.match?("d".to_slice).should be_true
    r.match?("x").should be_false
    r.match?("").should be_true
  end

  it "matches terminal introducers" do
    r = reader("\e[\e_\eP\e\\;\e]52;\e]label;")
    r.apc?.should be_false
    r.csi
    r.apc
    r.dcs
    r.st
    r.semi
    r.osc?(8).should be_false
    r.osc?("label").should be_false
    r.pos.should eq(9)
    r.osc(52)
    r.osc("label")
    r.eof?.should be_true
  end

  it "reads the span of base64 text" do
    r       = reader("aGVsbG8=;aGk")
    encoded = r.base64
    String.new(encoded).should eq("aGVsbG8=")
    String.new(Bytewire.new.decode64(encoded).written).should eq("hello")
    r.semi
    String.new(r.base64).should eq("aGk")
    r.base64.empty?.should be_true
  end

  it "reads values by type" do
    r = reader("-12é rest of it|end")
    r.read(Int16).should eq(-12_i16)
    r.read(Char).should eq('é')
    r.read?(UInt8).should be_nil
    r.match(' ')
    r.read(String, "|".to_slice).should eq("rest of it")
    r.read?(Bytes, "|x".to_slice).should be_nil
    r.match('|')
    String.new(r.read(Bytes)).should eq("end")
  end

  it "raises with the position from the raising forms" do
    r = reader("ab")
    r.byte
    error = expect_raises(Bytewire::Reader::Error, "expected an integer at byte 1") { r.int(Int32) }
    error.position.should eq(1)
    expect_raises(Bytewire::Reader::Error, "expected \"x\" at byte 1") { r.match("x") }
    expect_raises(Bytewire::Reader::Error, "expected CSI at byte 1") { r.csi }
    expect_raises(Bytewire::Reader::Error, "expected 5 byte(s) at byte 1") { r.take(5) }
    expect_raises(Bytewire::Reader::Error, "expected a value of type UInt8 at byte 1") { r.read(UInt8) }
    r.pos.should eq(1)
  end

  it "reads back what the builder writes" do
    builder = Bytewire.new(16)
    builder.csi.int(-12).semi.pad(7, 4).char('é').hex(0xbeef_u32).hex2(0x0a_u8).osc(52).str("x").st
    r = Bytewire::Reader.new(builder.written)
    r.csi
    r.int(Int32).should eq(-12)
    r.semi
    r.int(Int32, 4).should eq(7)
    r.char.should eq('é')
    r.hex(UInt32, 4).should eq(0xbeef_u32)
    r.hex2.should eq(0x0a_u8)
    r.osc(52)
    String.new(r.take_until("\e\\")).should eq("x")
    r.st
    r.eof?.should be_true
  end
end
