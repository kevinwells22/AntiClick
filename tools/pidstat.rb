#!/usr/bin/ruby
# frozen_string_literal: false
#
# pidstat.rb - measure what a process really costs over an interval.
#
#   ruby tools/pidstat.rb [--seconds N] PID [PID...]
#
# Reports CPU time used, CPU %, wakeups per second (package-idle + interrupt;
# the main driver of energy use for a mostly idle process) and memory
# footprint (the "Memory" figure Activity Monitor shows). Uses
# proc_pid_rusage(), which works for your own processes; for processes owned
# by other users (e.g. coreaudiod) it falls back to `ps` CPU time + RSS.

require 'fiddle'

LIBC = Fiddle::Handle::DEFAULT
F_RUSAGE = Fiddle::Function.new(LIBC['proc_pid_rusage'],
                                [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
F_TIMEBASE = Fiddle::Function.new(LIBC['mach_timebase_info'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
RUSAGE_INFO_V4 = 4

tb = "\0".b * 8
F_TIMEBASE.call(tb)
NUMER, DENOM = tb.unpack('L2')

# rusage_info_v4: uuid[16], then u64 user_time, system_time, pkg_idle_wkups,
# interrupt_wkups, pageins, wired_size, resident_size, phys_footprint, ...
def rusage(pid)
  buf = "\0".b * 1024
  return nil unless F_RUSAGE.call(pid, RUSAGE_INFO_V4, buf).zero?
  user, sys, idle, intr, _pageins, _wired, resident, footprint = buf.unpack('x16Q8')
  { cpu_ns: (user + sys) * NUMER / DENOM, wakeups: idle + intr, resident: resident, footprint: footprint }
end

def ps_sample(pid)
  t, rss = `ps -o time=,rss= -p #{pid} 2>/dev/null`.split
  return nil unless t
  secs = t.split(':').map(&:to_f).reverse.each_with_index.sum { |v, i| v * (60**i) }
  { cpu_ns: (secs * 1e9).to_i, wakeups: nil, resident: rss.to_i * 1024, footprint: nil }
end

def sample(pid)
  rusage(pid) || ps_sample(pid)
end

def mb(bytes)
  bytes ? format('%.1f MB', bytes / 1048576.0) : 'n/a'
end

seconds = 30.0
if (i = ARGV.index('--seconds'))
  seconds = ARGV[i + 1].to_f
  ARGV.slice!(i, 2)
end
pids = ARGV.map(&:to_i).reject(&:zero?)
abort 'usage: pidstat.rb [--seconds N] PID [PID...]' if pids.empty?

names = pids.to_h { |p| [p, `ps -o comm= -p #{p} 2>/dev/null`.strip.split('/').last || '?'] }
before = pids.to_h { |p| [p, sample(p)] }
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
sleep seconds
dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
after = pids.to_h { |p| [p, sample(p)] }

pids.each do |p|
  a = before[p]
  b = after[p]
  unless a && b
    puts format('%-7d %-22s (process not readable or exited)', p, names[p])
    next
  end
  cpu_ms = (b[:cpu_ns] - a[:cpu_ns]) / 1e6
  wake = a[:wakeups] && b[:wakeups] ? format('%7.1f/s', (b[:wakeups] - a[:wakeups]) / dt) : '    n/a'
  puts format('%-7d %-22s cpu=%8.1f ms in %.0fs (%6.3f%%)  wakeups=%s  footprint=%-9s rss=%s',
              p, names[p][0, 22], cpu_ms, dt, cpu_ms / (dt * 10), wake, mb(b[:footprint]), mb(b[:resident]))
end
