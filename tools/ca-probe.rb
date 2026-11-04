#!/usr/bin/ruby
# frozen_string_literal: false
#
# ca-probe.rb - CoreAudio diagnostics for AntiClick.
#
# Uses only the Ruby that ships with macOS (Fiddle FFI), so it works on a
# machine with no compiler / Xcode / Command Line Tools installed.
#
#   ruby tools/ca-probe.rb list                 # output devices + state
#   ruby tools/ca-probe.rb procs                # which processes are doing audio IO
#   ruby tools/ca-probe.rb watch [MATCH]        # print every start/stop of a device
#   ruby tools/ca-probe.rb hold  [MATCH] [--seconds N] [--buffer FRAMES]
#                                [--power-save] [--block-sleep]
#                                               # keep a device running (hardware
#                                               # start, no IOProc) until Ctrl-C
# MATCH is a case-insensitive substring of the device name or UID. Without it
# the current default output device is used.
#
# Constants below were verified against the macOS 27 CoreAudio BridgeSupport
# metadata (/System/Library/Frameworks/CoreAudio.framework/Resources/BridgeSupport).

require 'fiddle'

CA_LIB = Fiddle.dlopen('/System/Library/Frameworks/CoreAudio.framework/CoreAudio')
CF_LIB = Fiddle.dlopen('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')

I = Fiddle::TYPE_INT
P = Fiddle::TYPE_VOIDP
L = Fiddle::TYPE_LONG
C = Fiddle::TYPE_CHAR
V = Fiddle::TYPE_VOID

def cfunc(lib, name, args, ret)
  Fiddle::Function.new(lib[name], args, ret)
end

F_GET_SIZE = cfunc(CA_LIB, 'AudioObjectGetPropertyDataSize', [I, P, I, P, P], I)
F_GET      = cfunc(CA_LIB, 'AudioObjectGetPropertyData', [I, P, I, P, P, P], I)
F_SET      = cfunc(CA_LIB, 'AudioObjectSetPropertyData', [I, P, I, P, I, P], I)
F_START    = cfunc(CA_LIB, 'AudioDeviceStart', [I, P], I)
F_STOP     = cfunc(CA_LIB, 'AudioDeviceStop', [I, P], I)
F_CFSTR    = cfunc(CF_LIB, 'CFStringGetCString', [P, P, L, I], C)
F_CFREL    = cfunc(CF_LIB, 'CFRelease', [P], V)

SYSTEM_OBJECT  = 1
UTF8           = 0x08000100

TRANSPORTS = {
  'usb ' => 'USB', 'bltn' => 'Built-in', 'blue' => 'Bluetooth', 'blea' => 'BluetoothLE',
  'virt' => 'Virtual', 'grup' => 'Aggregate', 'fgrp' => 'AutoAggregate', 'hdmi' => 'HDMI',
  'dprt' => 'DisplayPort', 'airp' => 'AirPlay', 'thun' => 'Thunderbolt', 'pci ' => 'PCI',
  '1394' => 'FireWire', 'eavb' => 'AVB', 'ccwd' => 'Continuity(wired)', 'ccwl' => 'Continuity'
}.freeze

def fcc(str)
  str.unpack1('N')
end

def fcc_to_s(val)
  val &= 0xffffffff
  s = [val].pack('N')
  s.bytes.all? { |b| b.between?(0x20, 0x7e) } ? "'#{s}'" : val.to_s
end

def addr(sel, scope = 'glob', elem = 0)
  [fcc(sel), fcc(scope), elem].pack('L3')
end

# Returns [status, binary string or nil]
def get_raw(obj, sel, scope = 'glob', qual = nil)
  a = addr(sel, scope)
  qsz = qual ? qual.bytesize : 0
  size = [0].pack('L')
  st = F_GET_SIZE.call(obj, a, qsz, qual, size)
  return [st & 0xffffffff, nil] unless st.zero?
  n = size.unpack1('L')
  buf = "\0".b * [n, 8].max
  size = [n].pack('L')
  st = F_GET.call(obj, a, qsz, qual, size, buf)
  return [st & 0xffffffff, nil] unless st.zero?
  [0, buf[0, size.unpack1('L')]]
end

def u32(obj, sel, scope = 'glob', qual = nil)
  _, b = get_raw(obj, sel, scope, qual)
  b && b.bytesize >= 4 ? b.unpack1('L') : nil
end

def f64(obj, sel, scope = 'glob')
  _, b = get_raw(obj, sel, scope)
  b && b.bytesize >= 8 ? b.unpack1('d') : nil
end

def ids(obj, sel, scope = 'glob')
  _, b = get_raw(obj, sel, scope)
  b ? b.unpack('L*') : []
end

def cfstr(obj, sel, scope = 'glob')
  _, b = get_raw(obj, sel, scope)
  return nil unless b && b.bytesize == 8
  ptr = b.unpack1('Q')
  return nil if ptr.zero?
  out = "\0".b * 1024
  ok = F_CFSTR.call(ptr, out, out.bytesize, UTF8)
  F_CFREL.call(ptr)
  ok.zero? ? nil : out.split("\0").first.to_s.force_encoding('UTF-8')
end

def set_u32(obj, sel, value, scope = 'glob')
  st = F_SET.call(obj, addr(sel, scope), 0, nil, 4, [value].pack('L'))
  st & 0xffffffff
end

def channels(dev, scope)
  _, b = get_raw(dev, 'slay', scope)
  return 0 unless b && b.bytesize >= 4
  n = b.unpack1('L')
  (0...n).sum { |i| off = 8 + 16 * i; b.bytesize >= off + 4 ? b[off, 4].unpack1('L') : 0 }
end

def transport(dev)
  t = u32(dev, 'tran')
  return '?' unless t
  TRANSPORTS[[t].pack('N')] || fcc_to_s(t)
end

def output_devices
  ids(SYSTEM_OBJECT, 'dev#').select { |d| channels(d, 'outp') > 0 }
end

def pick_device(match)
  if match.nil? || match.empty?
    d = u32(SYSTEM_OBJECT, 'dOut')
    abort 'no default output device' if d.nil? || d.zero?
    return d
  end
  m = match.downcase
  found = output_devices.select do |d|
    [cfstr(d, 'lnam'), cfstr(d, 'uid ')].compact.any? { |s| s.downcase.include?(m) }
  end
  abort "no output device matches #{match.inspect}" if found.empty?
  warn "note: #{found.size} devices match #{match.inspect}; using the first" if found.size > 1
  found.first
end

def own_process_object
  u32(SYSTEM_OBJECT, 'id2p', 'glob', [Process.pid].pack('l'))
end

def stream_activity(dev)
  ids(dev, 'stm#', 'outp').map { |s| u32(s, 'sact') }
end

def ts
  Time.now.strftime('%H:%M:%S.%L')
end

def describe(dev)
  "#{cfstr(dev, 'lnam')} [#{transport(dev)}] id=#{dev}"
end

# ---------------------------------------------------------------- commands

def cmd_list
  dout = u32(SYSTEM_OBJECT, 'dOut')
  sout = u32(SYSTEM_OBJECT, 'sOut')
  output_devices.each do |d|
    flags = []
    flags << 'DEFAULT-OUT' if d == dout
    flags << 'SYSTEM-SOUNDS' if d == sout
    flags << 'hidden' if u32(d, 'hidn') == 1
    rng = get_raw(d, 'fsz#')[1]
    rng = rng ? rng.unpack('d2').map(&:to_i).join('..') : '?'
    puts format('%-4d %-26s %-12s out=%-2d in=%-2d %6.0f Hz  buf=%-5s range=%-10s running=%s streamsActive=%s %s',
                d, cfstr(d, 'lnam').to_s[0, 26], transport(d), channels(d, 'outp'), channels(d, 'inpt'),
                f64(d, 'nsrt') || 0, u32(d, 'fsiz'), rng, u32(d, 'gone') == 1 ? 'YES' : 'no',
                stream_activity(d).inspect, flags.join(' '))
    puts "     uid=#{cfstr(d, 'uid ')}"
  end
end

def cmd_procs
  list = ids(SYSTEM_OBJECT, 'prs#')
  if list.empty?
    puts 'process objects not available (needs macOS 14+)'
    return
  end
  any = false
  list.each do |p|
    ro = u32(p, 'piro')
    ri = u32(p, 'piri')
    next unless ro == 1 || ri == 1
    any = true
    pid = [u32(p, 'ppid').to_i].pack('L').unpack1('l')
    comm = `ps -p #{pid} -o comm= 2>/dev/null`.strip
    outs = ids(p, 'pdv#', 'outp').map { |d| cfstr(d, 'lnam') }
    ins  = ids(p, 'pdv#', 'inpt').map { |d| cfstr(d, 'lnam') }
    puts format('pid %-6d %-40s output=%-3s input=%-3s out-devs=%s in-devs=%s',
                pid, (cfstr(p, 'pbid') || File.basename(comm))[0, 40],
                ro == 1 ? 'YES' : 'no', ri == 1 ? 'YES' : 'no', outs.inspect, ins.inspect)
  end
  puts 'no process is currently running audio IO' unless any
end

def cmd_watch(match)
  dev = pick_device(match)
  puts "#{ts}  watching #{describe(dev)} (Ctrl-C to stop)"
  last = nil
  since = Time.now
  trap('INT') { puts; exit 0 }
  loop do
    rs = u32(dev, 'gone')
    if rs != last
      now = Time.now
      dur = last.nil? ? '' : format('  (previous state lasted %.2fs)', now - since)
      puts "#{ts}  #{rs == 1 ? 'RUNNING' : 'stopped'}#{dur}"
      last = rs
      since = now
    end
    sleep 0.02
  end
end

def thread_count
  `ps -M -p #{Process.pid} 2>/dev/null`.lines.size - 1
end

def cmd_hold(match, seconds, block_sleep, buffer = nil, power_save = false)
  unless block_sleep
    st = set_u32(SYSTEM_OBJECT, 'slep', 1)
    puts "#{ts}  SleepingIsAllowed=1 -> #{st.zero? ? 'ok' : "error #{fcc_to_s(st)}"}"
  end
  if power_save
    st = set_u32(SYSTEM_OBJECT, 'powh', 1)
    puts "#{ts}  PowerHint=FavorSavingPower -> #{st.zero? ? 'ok' : "error #{fcc_to_s(st)}"}"
  end
  dev = pick_device(match)
  if buffer
    st = set_u32(dev, 'fsiz', buffer)
    puts "#{ts}  BufferFrameSize=#{buffer} -> #{st.zero? ? 'ok' : "error #{fcc_to_s(st)}"} (now #{u32(dev, 'fsiz')})"
  end
  threads_before = thread_count
  st = F_START.call(dev, nil) & 0xffffffff
  puts "#{ts}  AudioDeviceStart(#{describe(dev)}, NULL) -> #{st.zero? ? 'ok' : "error #{fcc_to_s(st)}"}"
  sleep 0.5
  me = own_process_object
  puts "#{ts}  device running in this process=#{u32(dev, 'goin')} somewhere=#{u32(dev, 'gone')} " \
       "output streams active=#{stream_activity(dev).inspect}"
  if me && !me.zero?
    puts "#{ts}  this process: IsRunningOutput=#{u32(me, 'piro')} IsRunningInput=#{u32(me, 'piri')}"
  end
  puts "#{ts}  threads before start=#{threads_before} after=#{thread_count}  pid=#{Process.pid}"
  stop = lambda do
    st2 = F_STOP.call(dev, nil) & 0xffffffff
    puts "\n#{ts}  AudioDeviceStop -> #{st2.zero? ? 'ok' : fcc_to_s(st2)}"
    exit 0
  end
  trap('INT') { stop.call }
  trap('TERM') { stop.call }
  if seconds
    sleep seconds
    stop.call
  else
    puts "#{ts}  holding device open; press Ctrl-C to release"
    sleep
  end
end

# ---------------------------------------------------------------- main

cmd = ARGV.shift
case cmd
when 'list'  then cmd_list
when 'procs' then cmd_procs
when 'watch' then cmd_watch(ARGV.reject { |a| a.start_with?('--') }.first)
when 'hold'
  secs = nil
  if (i = ARGV.index('--seconds'))
    secs = ARGV[i + 1].to_f
    ARGV.slice!(i, 2)
  end
  buf = nil
  if (i = ARGV.index('--buffer'))
    buf = ARGV[i + 1].to_i
    ARGV.slice!(i, 2)
  end
  block = !ARGV.delete('--block-sleep').nil?
  psave = !ARGV.delete('--power-save').nil?
  cmd_hold(ARGV.reject { |a| a.start_with?('--') }.first, secs, block, buf, psave)
else
  puts File.read(__FILE__).lines[2..16].map { |l| l.sub(/^# ?/, '') }.join
  exit(cmd.nil? ? 0 : 1)
end
