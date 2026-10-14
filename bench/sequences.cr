# bench/sequences.cr
require "./bench_helper"

Bytewire.template BenchMove, "\e[#{row : Int32};#{col : Int32}H"

Bytewire.template BenchCell, "\e[#{row : Int32};#{col : Int32}H\e[38;2;#{red : UInt8};#{green : UInt8};#{blue : UInt8}m#{name : String}"

Bytewire.template BenchNestedCell, "#{at : BenchMove}\e[38;2;#{red : UInt8};#{green : UInt8};#{blue : UInt8}m#{name : String}"

Bytewire.template BenchColumns, ",c=#{value : Int32}"

Bytewire.template BenchRows, ",r=#{value : Int32}"

Bytewire.template BenchControl, "\e_Ga=p,i=#{id : Int32}#{columns : BenchColumns?}#{rows : BenchRows?},z=#{layer : Int32}\e\\"

Bytewire.template BenchSpace, " "

Bytewire.template BenchClipboard, "\e]52;#{kinds : Bytewire::List(String, BenchSpace)}\e\\"

rows   = Array.new(Bench::BATCH * 2) { |i| (i * 7) % 200 + 1 }
name   = "label"
absent = nil.as(Int32?)
b      = Bytewire.new(1 << 16)
memory = IO::Memory.new(1 << 16)

Bench.group("cursor move and rgb colour, #{Bench::BATCH} per iteration") do |job|
  job.report("interpolation + str") do
    b.reset
    Bench::BATCH.times do |i|
      row = rows.unsafe_fetch(i)
      col = rows.unsafe_fetch(i + Bench::BATCH)
      r   = col & 255
      b.str("\e[#{row};#{col}H\e[38;2;#{r};#{r};#{r}m#{name}")
    end
    Bench.keep(b)
  end
  job.report("IO::Memory <<") do
    memory.clear
    Bench::BATCH.times do |i|
      row = rows.unsafe_fetch(i)
      col = rows.unsafe_fetch(i + Bench::BATCH)
      r   = col & 255
      memory << "\e[" << row << ';' << col << "H\e[38;2;" << r << ';' << r << ';' << r << 'm' << name
    end
    Bench.keep(memory)
  end
  job.report("chained appends") do
    b.reset
    Bench::BATCH.times do |i|
      row = rows.unsafe_fetch(i)
      col = rows.unsafe_fetch(i + Bench::BATCH)
      r   = col & 255
      b.str("\e[").int(row).semi.int(col).str("H\e[38;2;").int3(r).semi.int3(r).semi.int3(r).char('m').str(name)
    end
    Bench.keep(b)
  end
  job.report("template") do
    b.reset
    Bench::BATCH.times do |i|
      row = rows.unsafe_fetch(i)
      col = rows.unsafe_fetch(i + Bench::BATCH)
      r   = (col & 255).to_u8!
      b << BenchCell.new(row: row, col: col, red: r, green: r, blue: r, name: name)
    end
    Bench.keep(b)
  end
  job.report("template nesting a template") do
    b.reset
    Bench::BATCH.times do |i|
      row = rows.unsafe_fetch(i)
      col = rows.unsafe_fetch(i + Bench::BATCH)
      r   = (col & 255).to_u8!
      b << BenchNestedCell.new(at: BenchMove.new(row: row, col: col), red: r, green: r, blue: r, name: name)
    end
    Bench.keep(b)
  end
end

Bench.group("control string with optional fields, #{Bench::BATCH} per iteration") do |job|
  job.report("interpolation + str") do
    b.reset
    Bench::BATCH.times do |i|
      columns = rows.unsafe_fetch(i)
      control = "a=p,i=#{i}"
      control = "#{control},c=#{columns}" if columns
      control = "#{control},r=#{absent}" if absent
      control = "#{control},z=#{columns}"
      b.str("\e_G#{control}\e\\")
    end
    Bench.keep(b)
  end
  job.report("chained field") do
    b.reset
    Bench::BATCH.times do |i|
      columns = rows.unsafe_fetch(i)
      b.apc.str("Ga=p,i=").int(i).field(",c=", columns).field(",r=", absent).field(",z=", columns).st
    end
    Bench.keep(b)
  end
  job.report("template with optional fields") do
    b.reset
    Bench::BATCH.times do |i|
      columns = rows.unsafe_fetch(i)
      b << BenchControl.new(id: i, columns: BenchColumns.new(value: columns), rows: nil, layer: columns)
    end
    Bench.keep(b)
  end
end

Bench.group("separated list of 8 strings, #{Bench::BATCH} per iteration") do |job|
  mimes = Array.new(8) { |i| "application/x-type-#{i}" }
  job.report("interpolation + join") do
    b.reset
    Bench::BATCH.times { b.str("\e]52;#{mimes.join(' ')}\e\\") }
    Bench.keep(b)
  end
  job.report("chained appends in a loop") do
    b.reset
    Bench::BATCH.times do
      b.osc(52)
      mimes.each_with_index do |mime, index|
        b.byte(0x20_u8) if index > 0
        b.str(mime)
      end
      b.st
    end
    Bench.keep(b)
  end
  job.report("template with a list") do
    b.reset
    Bench::BATCH.times { b << BenchClipboard.new(kinds: mimes) }
    Bench.keep(b)
  end
end
