# frozen_string_literal: true

module GoodSorcery
  module Performance
    # Per-process, per-minute metrics (DESIGN.md 8.4). Keyed by the minute in
    # which a unit of work finished (integer Unix minutes), then kind, then
    # name. At most MAX_TRANSACTIONS names per kind per minute (the rest are
    # counted under "(other)") and MAX_PENDING_MINUTES minutes are held.
    class Aggregator
      MAX_TRANSACTIONS = 500
      MAX_PENDING_MINUTES = 5
      OTHER = "(other)"

      attr_reader :dropped_minutes

      def initialize
        @lock = Mutex.new
        @minutes = {}
        @dropped_minutes = 0
      end

      def record(minute, sample)
        @lock.synchronize do
          names = (minute_table(minute)[sample.kind] ||= {})
          name = names.key?(sample.name) || names.size < MAX_TRANSACTIONS ? sample.name : OTHER
          (names[name] ||= TransactionStats.new).add(sample, keep_labels: name != OTHER)
        end
      end

      # Removes and returns the minutes up to and including +last_minute+
      # (all of them when nil), oldest first: [[minute, {kind => {name => stats}}]].
      def take(last_minute = nil)
        @lock.synchronize do
          taken = @minutes.keys.sort.select { |minute| last_minute.nil? || minute <= last_minute }
          taken.map { |minute| [minute, @minutes.delete(minute)] }
        end
      end

      def minutes
        @lock.synchronize { @minutes.keys.sort }
      end

      def empty?
        @lock.synchronize { @minutes.empty? }
      end

      private

      def minute_table(minute)
        table = @minutes[minute]
        return table if table

        drop_oldest while @minutes.size >= MAX_PENDING_MINUTES
        @minutes[minute] = {}
      end

      def drop_oldest
        @minutes.delete(@minutes.keys.min)
        @dropped_minutes += 1
      end
    end
  end
end
