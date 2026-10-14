# src/bytewire/sink.cr
class Bytewire
  class Sink < ::IO
    def initialize(@builder : Bytewire)
    end

    def read(slice : Bytes) : NoReturn
      raise ::IO::Error.new("Bytewire is write-only")
    end

    def write(slice : Bytes) : Nil
      @builder.bytes(slice)
    end

    def write_byte(byte : UInt8) : Nil
      @builder.byte(byte)
    end
  end

  def io : Sink
    @io ||= Sink.new(self)
  end
end
