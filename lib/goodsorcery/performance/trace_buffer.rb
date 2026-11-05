# frozen_string_literal: true

module GoodSorcery
  module Performance
    # Holds the slowest trace per transaction per minute (DESIGN.md 8.5).
    # +candidate?+ is the cheap check made for every unit of work; only a
    # candidate's trace is built (outside the lock), then +offer+ swaps it in
    # if it is still the slowest. At most MAX_TRACES_PER_MINUTE traces per
    # minute: when full, a new transaction's trace replaces the fastest one
    # held, and only if it is slower.
    class TraceBuffer
      MAX_TRACES_PER_MINUTE = 30
      MAX_MINUTES = Aggregator::MAX_PENDING_MINUTES

      Entry = Struct.new(:duration_ms, :trace)

      def initialize
        @lock = Mutex.new
        @minutes = {}
      end

      def candidate?(minute, key, duration_ms)
        @lock.synchronize { slower?(@minutes[minute], key, duration_ms) }
      end

      # => true when the trace was kept.
      def offer(minute, key, duration_ms, trace)
        @lock.synchronize do
          entries = minute_entries(minute)
          next false unless slower?(entries, key, duration_ms)

          evict_fastest(entries) if !entries.key?(key) && entries.size >= MAX_TRACES_PER_MINUTE
          entries[key] = Entry.new(duration_ms, trace)
          true
        end
      end

      # Removes and returns the traces of the minutes up to +last_minute+
      # (all when nil), slowest first.
      def take(last_minute = nil)
        @lock.synchronize do
          minutes = @minutes.keys.select { |minute| last_minute.nil? || minute <= last_minute }
          entries = minutes.flat_map { |minute| @minutes.delete(minute).values }
          entries.sort_by { |entry| -entry.duration_ms }.map(&:trace)
        end
      end

      def size
        @lock.synchronize { @minutes.values.sum(&:size) }
      end

      private

      def slower?(entries, key, duration_ms)
        return true if entries.nil?

        held = entries[key]
        return duration_ms > held.duration_ms if held
        return true if entries.size < MAX_TRACES_PER_MINUTE

        duration_ms > entries.values.min_by(&:duration_ms).duration_ms
      end

      def evict_fastest(entries)
        key, = entries.min_by { |_key, entry| entry.duration_ms }
        entries.delete(key)
      end

      def minute_entries(minute)
        entries = @minutes[minute]
        return entries if entries

        @minutes.delete(@minutes.keys.min) while @minutes.size >= MAX_MINUTES
        @minutes[minute] = {}
      end
    end
  end
end
