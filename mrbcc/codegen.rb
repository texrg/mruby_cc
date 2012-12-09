# encoding: utf-8
require 'active_support/core_ext'
require 'securerandom'
require_relative './rite_parser'

class OpcodeParser
  attr_reader :name, :irep, :opcodes
  DEBUG_MODE = false
  def initialize(parser, opcodes, name, irep_idx)
    @name = name || "met_#{SecureRandom.hex}"
    @irep = parser.ireps[irep_idx]
    @parser = parser
    @irep_idx = irep_idx
    @opcodes = opcodes
  end

  def label(i = nil)
    i ||= @line_number
    "L_#{@name.upcase}_#{i}"
  end

  def process_irep
    @outf = StringIO.new
    @outf.write(method_prelude)
    irep.iseqs.each.with_index do |instr, line_number|
      puts instr if DEBUG_MODE

      @instr = instr
      @line_number = line_number
      @opcode = instr.opcode

      @instr_body = opcodes[@opcode].dup
      if respond_to?(@opcode.downcase)
        send(@opcode.downcase)
      end

      gsub_args

      # symbols
      @instr_body.gsub!(/syms\[([^\]]+)\]/) do
        "mrb_intern(mrb, \"#{irep.syms[$1.to_i]}\")"
      end
      # string literals
      @instr_body.gsub!(/mrb_str_literal\(mrb, (pool\[[^\]]+\])\)/) do
        $1
      end
      # pool
      @instr_body.gsub!(/pool\[([^\]]+)\]/) do
        val = irep.pool[$1.to_i]
        val = case val
        when Float
          "mrb_float_value(#{val})"
        when Fixnum
          "mrb_fixnum_value(#{val})"
        when String
          # TODO fix this so we can load binary strings too
          val.gsub!('"', '\\"');
          "mrb_str_new_cstr(mrb, \"#{val}\")"
        when Regexp
          # TODO
          raise
        else
          val
        end
      end
      # raise
      @instr_body.gsub!("goto L_RAISE;", "mrbb_raise(mrb, prev_jmp);")

      @outf.write("\n  // #{instr}")

      @outf.write("\n  #{label}:\n  ")
      if DEBUG_MODE
        @outf.write("  printf(\"#{label}\\n\"); fflush(stdout);\n")
      end
      @outf.write(@instr_body)
    end
    wrap_body(@outf.string)
  end

  def wrap_body(body)
    "#{body}\n}\n"
  end

  def method_prelude
    prelude = File.read(File.expand_path("../codegen_rb/met_start.c", __FILE__))
    prelude.gsub("FUNC_NREGS", irep.nregs.to_s).
      gsub("MET_NAME", @name)
  end

  def parse_args(args)
    args.map do |arg|
      if arg =~ /\AR(\d+)\z/
        $1
      elsif arg =~ /\A:/
        sym_str = arg[1, arg.length-1]
        #"mrb_intern(mrb, \"#{sym_str}\")"
        "\"#{sym_str}\""
      elsif arg =~/\A"/
        arg
      elsif arg =~/\A\d+\z/
        arg
      elsif arg =~ /\AI\((\d+)\)\z/
        parser = OpcodeParser.new(nil, opcodes, $1.to_i + @irep_idx)
        str = parser.process_irep
        @outf = StringIO.new(str + @outf.string)
        @outf.seek(0, IO::SEEK_END)
        parser.name
      else
        arg
      end
    end
  end

  def gsub_args
    ["GETARG_A", "GETARG_Ax"].each do |search_str|
      @instr_body.gsub!("#{search_str}(i)", @instr.send(search_str).to_s)
    end
    ["GETARG_B", "GETARG_Bx", "GETARG_sBx", "GETARG_b"].each do |search_str|
      @instr_body.gsub!("#{search_str}(i)", @instr.send(search_str).to_s)
    end
    ["GETARG_C", "GETARG_c"].each do |search_str|
      @instr_body.gsub!("#{search_str}(i)", @instr.send(search_str).to_s)
    end
  end

  def fix_lsend_2arg(met_name)
    @instr_body.gsub!("goto L_SEND;",
      "regs[a] = mrb_funcall_with_block(mrb, regs[a], " +
      "mrb_intern(mrb, \"#{met_name}\"), 1, &regs[a+1], mrb_nil_value());")
  end

  def lambda_arg_precompiled(parser, arg_name)
    @instr_body.gsub!("#{arg_name}(i)", parser.name)
    @instr_body.gsub!("GETIREP_BLK_NREGS()", parser.irep.nregs.to_s)
    @instr_body.gsub!("GETIREP_NLOCALS()", @irep.nlocals.to_s)
  end

  def lambda_arg(arg_name)
    parser = OpcodeParser.new(@parser, opcodes, nil, @irep_idx + @instr.send(arg_name))
    str = parser.process_irep
    @outf = StringIO.new(str + @outf.string)
    @outf.seek(0, IO::SEEK_END)
    lambda_arg_precompiled(parser, arg_name)
    parser
  end
# OPCODES
  def op_exec
    lambda_arg("GETARG_Bx")
  end

  def op_lambda
    lambda_arg("GETARG_b")
  end

  def op_epush
    @ensure_parser = lambda_arg("GETARG_Bx")
  end

  def op_return
    # todo
  end

  def op_send
  end

  def op_sendb
    op_send
  end

  def op_sub
    fix_lsend_2arg("-")
  end

  def op_add
    fix_lsend_2arg("+")
  end

  def op_subi
    op_sub
    @instr_body.gsub!(/i = MKOP_ABC\(OP_SEND.*/, "")
  end

  def op_addi
    op_add
    @instr_body.gsub!(/i = MKOP_ABC\(OP_SEND.*/, "")
  end

  def op_mul
    fix_lsend_2arg("*")
  end

  def op_div
    fix_lsend_2arg("/")
  end

  def op_enter
    ax = @instr.GETARG_Ax
    m1 = (ax>>18)&0x1f
    o  = (ax>>13)&0x1f
    r  = (ax>>12)&0x1
    m2 = (ax>>7)&0x1f

    len = m1 + o + r + m2
    # jumps
    @instr_body.gsub!(/if \(o == 0\)([^;]+;)\s*else([^;]+;)/m) do
      if o == 0
        $1
      else
        $2
      end
    end
    @instr_body.gsub!("pc++", "goto #{label(@line_number+1)}")
    @instr_body.gsub!("pc += argc - m1 - m2 + 1;") do
      str = "switch(argc) {\n"
      # TODO must raise error if too little arguments?
      ((m1+m2)..len-1).each do |i|
        str += "  case #{i}: goto #{label(@line_number+i-m1-m2+1)};\n"
      end
      str += "}\n"
      str
    end
    @instr_body.gsub!("pc += o + 1;", "goto #{label(@line_number+o+1)};")
    @instr_body.gsub!("JUMP;", "")
  end

  def op_jmp
    @instr_body = "goto #{label(@line_number + @instr.GETARG_sBx)};"
  end

  def op_jmpif
    tmp = "pc += GETARG_sBx(i);"
    @instr_body.gsub!(/#{Regexp.escape(tmp)}\s*JUMP;/,
      "goto #{label(@line_number + @instr.GETARG_sBx)};")
  end

  def op_onerr
    @instr_body.gsub!("rescue_label(GETARG_sBx(i))",
      label(@line_number + @instr.GETARG_sBx))
    #tmp = "pc += GETARG_sBx(i);"
    #@instr_body.gsub!(/#{Regexp.escape(tmp)}\s*JUMP;/,
    #  "goto #{label(@line_number + @instr.GETARG_sBx)};")
  end

  def op_jmpnot
    op_jmpif
  end
end