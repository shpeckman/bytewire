# spec/template_spec.cr
require "./spec_helper"

module TemplateSpec
  Bytewire.template Semi, ";"
  Bytewire.template Cursor, "\e[#{row : Int32};#{col : Int32}H"
  Bytewire.template Color, "##{red : Bytewire::Hex2}#{green : Bytewire::Hex2}#{blue : Bytewire::Hex2}"
  Bytewire.template Title, ";#{text : String}"
  Bytewire.template Cell, "#{at : Cursor}#{color : Color}#{title : Title?}\e\\"
  Bytewire.template Style, "\e[#{params : Bytewire::List(UInt8, Semi)}m"
  Bytewire.template Path, "#{points : Bytewire::List(Cursor, Semi)}."
  Bytewire.template Stamp, "#{year : Bytewire::Padded(Int32, 4)}-#{month : Bytewire::Padded(UInt8, 2)} #{mask : Bytewire::Hex(UInt32)}"
  Bytewire.template Payload, "\e]52;#{text : Bytewire::Base64(String)};#{raw : Bytewire::Base64(Bytes)}\a"
  Bytewire.template Pair, "#{key : Bytes}=#{value : String}"
  Bytewire.template Line, "<#{pair : Pair}>#{mark : Char}#{level : UInt8}"
  Bytewire.template Wide, "#{small : Int8},#{large : UInt128},#{signed : Int64}"
  Bytewire.template Columns, ",c=#{value : Int32}"
  Bytewire.template Rows, ",r=#{value : Int32}"
  Bytewire.template Control, "\e_Gi=#{id : Int32}#{columns : Columns?}#{rows : Rows?},z=#{layer : Int32}\e\\"
  Bytewire.template Space, " "
  Bytewire.template Comma, ", "
  Bytewire.template Clipboard, "\e]52;#{kinds : Bytewire::List(String, Space)}\e\\"
  Bytewire.template Names, "#{names : Bytewire::List(Bytes, Comma)}"
  Bytewire.template Roster, "[#{names : Names}]#{count : Int32}"
  Bytewire.template Quoted, "#{text : String}''"
end

private def round_trip(value : T) : T forall T
  builder = Bytewire.new(16)
  builder << value
  reader = Bytewire::Reader.new(builder.written)
  result = T.read(reader)
  reader.eof?.should be_true
  result
end

describe "Bytewire.template" do
  it "writes a value and reads it back" do
    builder = Bytewire.new(16)
    cursor  = TemplateSpec::Cursor.new(row: 12, col: 40)
    builder << cursor << TemplateSpec::Cursor.new(col: -2, row: 1)
    text(builder).should eq("\e[12;40H\e[1;-2H")
    reader = Bytewire::Reader.new(builder.written)
    first  = TemplateSpec::Cursor.read(reader)
    first.should eq(cursor)
    first.row.should eq(12)
    first.col.should eq(40)
    TemplateSpec::Cursor.read?(reader).should eq(TemplateSpec::Cursor.new(row: 1, col: -2))
    TemplateSpec::Cursor.read?(reader).should be_nil
    reader.eof?.should be_true
  end

  it "restores the cursor and leaves nothing behind when reading fails" do
    reader = Bytewire::Reader.new("x\e[12;40Q")
    reader.byte
    TemplateSpec::Cursor.read?(reader).should be_nil
    reader.pos.should eq(1)
    error = expect_raises(Bytewire::Reader::Error, "expected TemplateSpec::Cursor at byte 1") do
      TemplateSpec::Cursor.read(reader)
    end
    error.position.should eq(1)
  end

  it "encodes fields through format types" do
    builder = Bytewire.new(16)
    stamp   = TemplateSpec::Stamp.new(year: 7, month: 3_u8, mask: 0xbeef_u32)
    builder << stamp << TemplateSpec::Color.new(red: 255_u8, green: 128_u8, blue: 0_u8)
    text(builder).should eq("0007-03 beef#ff8000")
    reader = Bytewire::Reader.new(builder.written)
    TemplateSpec::Stamp.read(reader).should eq(stamp)
    TemplateSpec::Color.read(reader).green.should eq(128_u8)
    round_trip(TemplateSpec::Stamp.new(year: -12345, month: 255_u8, mask: UInt32::MAX)).year.should eq(-12345)
  end

  it "rejects padded numbers that are too short" do
    TemplateSpec::Stamp.read?(Bytewire::Reader.new("0007-03 0")).should_not be_nil
    TemplateSpec::Stamp.read?(Bytewire::Reader.new("007-03 0")).should be_nil
    TemplateSpec::Stamp.read?(Bytewire::Reader.new("0007-3 0")).should be_nil
    TemplateSpec::Stamp.read?(Bytewire::Reader.new("-0007-03 0")).should_not be_nil
  end

  it "encodes and decodes base64 fields" do
    builder = Bytewire.new(16)
    payload = TemplateSpec::Payload.new(text: "hello", raw: Bytes[0, 255, 16])
    builder << payload << TemplateSpec::Payload.new(text: "", raw: Bytes.empty)
    text(builder).should eq("\e]52;aGVsbG8=;AP8Q\a\e]52;;\a")
    reader = Bytewire::Reader.new(builder.written)
    first  = TemplateSpec::Payload.read(reader)
    first.text.should eq("hello")
    first.raw.should eq(Bytes[0, 255, 16])
    TemplateSpec::Payload.read(reader).text.should eq("")
    TemplateSpec::Payload.read?(Bytewire::Reader.new("\e]52;aGVsb;AP8Q\a")).should be_nil
  end

  it "writes nothing for a missing optional field and reads it back as nil" do
    at      = TemplateSpec::Cursor.new(row: 1, col: 2)
    color   = TemplateSpec::Color.new(red: 1_u8, green: 2_u8, blue: 3_u8)
    titled  = TemplateSpec::Cell.new(at: at, color: color, title: TemplateSpec::Title.new(text: "né; x"))
    plain   = TemplateSpec::Cell.new(at: at, color: color, title: nil)
    builder = Bytewire.new(16)
    builder << titled << plain
    text(builder).should eq("\e[1;2H#010203;né; x\e\\\e[1;2H#010203\e\\")
    reader = Bytewire::Reader.new(builder.written)
    TemplateSpec::Cell.read(reader).should eq(titled)
    second = TemplateSpec::Cell.read(reader)
    second.title.should be_nil
    second.at.col.should eq(2)
    reader.eof?.should be_true
  end

  it "writes and reads lists with their separator" do
    builder = Bytewire.new(16)
    builder << TemplateSpec::Style.new(params: [] of UInt8) << TemplateSpec::Style.new(params: [7_u8]) << TemplateSpec::Style.new(params: [1_u8, 38_u8, 255_u8])
    text(builder).should eq("\e[m\e[7m\e[1;38;255m")
    reader = Bytewire::Reader.new(builder.written)
    TemplateSpec::Style.read(reader).params.empty?.should be_true
    TemplateSpec::Style.read(reader).params.should eq([7_u8])
    TemplateSpec::Style.read(reader).params.should eq([1_u8, 38_u8, 255_u8])
    TemplateSpec::Style.read?(Bytewire::Reader.new("\e[1;m")).should be_nil
    TemplateSpec::Style.read?(Bytewire::Reader.new("\e[256m")).should be_nil
    points = [TemplateSpec::Cursor.new(row: 1, col: 2), TemplateSpec::Cursor.new(row: 3, col: 4)]
    round_trip(TemplateSpec::Path.new(points: points)).points.should eq(points)
  end

  it "reads strings and bytes up to the text that follows them, or to the end" do
    builder = Bytewire.new(16)
    builder << TemplateSpec::Line.new(pair: TemplateSpec::Pair.new(key: "key".to_slice, value: "a=b"), mark: 'é', level: 255_u8)
    text(builder).should eq("<key=a=b>é255")
    reader = Bytewire::Reader.new(builder.written)
    line   = TemplateSpec::Line.read(reader)
    String.new(line.pair.key).should eq("key")
    line.pair.value.should eq("a=b")
    line.mark.should eq('é')
    line.level.should eq(255_u8)
    pair = TemplateSpec::Pair.read(Bytewire::Reader.new("=rest > of it"))
    pair.key.empty?.should be_true
    pair.value.should eq("rest > of it")
  end

  it "refuses to write a string that contains the text that ends it" do
    builder = Bytewire.new(16)
    builder << TemplateSpec::Cursor.new(row: 1, col: 1)
    expect_raises(ArgumentError, %("k=v" contains "=", the text that ends it)) do
      builder << TemplateSpec::Pair.new(key: "k=v".to_slice, value: "x")
    end
    expect_raises(ArgumentError, %("a>b" contains ">", the text that ends it)) do
      builder << TemplateSpec::Line.new(pair: TemplateSpec::Pair.new(key: "k".to_slice, value: "a>b"), mark: 'x', level: 0_u8)
    end
    text(builder).should eq("\e[1;1H")
  end

  it "refuses to write a string whose end would be found too early" do
    builder = Bytewire.new(16)
    expect_raises(ArgumentError, %("it'" contains "''", the text that ends it)) do
      builder << TemplateSpec::Quoted.new(text: "it'")
    end
    builder.empty?.should be_true
    round_trip(TemplateSpec::Quoted.new(text: "it's")).text.should eq("it's")
  end

  it "tells apart optional segments that begin with the same characters" do
    both    = TemplateSpec::Control.new(id: 1, columns: TemplateSpec::Columns.new(value: 80), rows: TemplateSpec::Rows.new(value: 24), layer: -1)
    second  = TemplateSpec::Control.new(id: 2, columns: nil, rows: TemplateSpec::Rows.new(value: 24), layer: 0)
    neither = TemplateSpec::Control.new(id: 3, columns: nil, rows: nil, layer: 7)
    builder = Bytewire.new(16)
    builder << both << second << neither
    text(builder).should eq("\e_Gi=1,c=80,r=24,z=-1\e\\\e_Gi=2,r=24,z=0\e\\\e_Gi=3,z=7\e\\")
    reader = Bytewire::Reader.new(builder.written)
    TemplateSpec::Control.read(reader).should eq(both)
    TemplateSpec::Control.read(reader).should eq(second)
    TemplateSpec::Control.read(reader).should eq(neither)
    reader.eof?.should be_true
  end

  it "writes and reads lists of strings" do
    builder = Bytewire.new(16)
    builder << TemplateSpec::Clipboard.new(kinds: ["text/plain", "é", "image/png"])
    builder << TemplateSpec::Clipboard.new(kinds: [] of String)
    builder << TemplateSpec::Clipboard.new(kinds: ["", "a", ""])
    text(builder).should eq("\e]52;text/plain é image/png\e\\\e]52;\e\\\e]52; a \e\\")
    reader = Bytewire::Reader.new(builder.written)
    TemplateSpec::Clipboard.read(reader).kinds.should eq(["text/plain", "é", "image/png"])
    TemplateSpec::Clipboard.read(reader).kinds.empty?.should be_true
    TemplateSpec::Clipboard.read(reader).kinds.should eq(["", "a", ""])
    reader.eof?.should be_true
  end

  it "reads a list of byte slices to the end of the input or to the enclosing text" do
    names = TemplateSpec::Names.read(Bytewire::Reader.new("ada, grace, hopper"))
    names.names.map { |name| String.new(name) }.should eq(["ada", "grace", "hopper"])
    reader = Bytewire::Reader.new("ada, grace,hopper")
    TemplateSpec::Names.read(reader).names.size.should eq(2)
    reader.pos.should eq(10)
    TemplateSpec::Names.read(Bytewire::Reader.new("")).names.empty?.should be_true
    roster  = TemplateSpec::Roster.new(names: TemplateSpec::Names.new(names: ["ada".to_slice, "grace".to_slice]), count: 2)
    builder = Bytewire.new(16)
    builder << roster
    text(builder).should eq("[ada, grace]2")
    round_trip(roster).should eq(roster)
  end

  it "refuses to write list items that could not be read back" do
    builder = Bytewire.new(16)
    expect_raises(ArgumentError, %("two words" contains ' ', which begins the text that ends a list item)) do
      builder << TemplateSpec::Clipboard.new(kinds: ["one", "two words"])
    end
    expect_raises(ArgumentError, %("a\\eb" contains '\\e', which begins the text that ends a list item)) do
      builder << TemplateSpec::Clipboard.new(kinds: ["a\eb"])
    end
    expect_raises(ArgumentError, %("a]" contains ']', which begins the text that ends a list item)) do
      builder << TemplateSpec::Roster.new(names: TemplateSpec::Names.new(names: ["a]".to_slice]), count: 1)
    end
    expect_raises(ArgumentError, "a list holding one empty item cannot be told apart from an empty list") do
      builder << TemplateSpec::Clipboard.new(kinds: [""])
    end
    builder.empty?.should be_true
  end

  it "handles every integer width and literal-only templates" do
    wide = TemplateSpec::Wide.new(small: Int8::MIN, large: UInt128::MAX, signed: Int64::MIN)
    round_trip(wide).should eq(wide)
    builder = Bytewire.new(16)
    builder << TemplateSpec::Semi.new << TemplateSpec::Semi.new
    text(builder).should eq(";;")
    reader = Bytewire::Reader.new(";x")
    TemplateSpec::Semi.read?(reader).should eq(TemplateSpec::Semi.new)
    TemplateSpec::Semi.read?(reader).should be_nil
  end

  it "reserves once for a value larger than the buffer" do
    builder = Bytewire.new(16)
    title   = TemplateSpec::Title.new(text: "x" * 500)
    builder << title
    builder.pos.should eq(501)
    TemplateSpec::Title.bound(title).should eq(501)
    round_trip(title).should eq(title)
  end

  it "reads many values through one reused reader" do
    reader = Bytewire::Reader.new("\e[1;2H")
    TemplateSpec::Cursor.read(reader).row.should eq(1)
    reader.reset("\e[3;4H")
    TemplateSpec::Cursor.read(reader).row.should eq(3)
    reader.reset("\e[5;6H".to_slice)
    TemplateSpec::Cursor.read(reader).col.should eq(6)
    reader.reset
    reader.pos.should eq(0)
  end
end
