# bench/bench_helper.cr
require "benchmark"
require "base64"
require "../src/bytewire"

module Bench
  WARMUP      = 500.milliseconds
  CALCULATION = 2.seconds
  BATCH       =  256
  LARGE_BATCH = 4096

  class_property sink = 0_u64

  def self.group(title : String, & : Benchmark::IPS::Job ->) : Nil
    puts
    puts title
    Benchmark.ips(warmup: WARMUP, calculation: CALCULATION) { |job| yield job }
  end

  def self.keep(builder : Bytewire) : Nil
    @@sink &+= builder.pos
  end

  def self.keep(io : IO::Memory) : Nil
    @@sink &+= io.pos
  end

  def self.keep(text : String) : Nil
    @@sink &+= text.bytesize
  end
end
