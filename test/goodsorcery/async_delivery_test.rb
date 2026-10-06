# frozen_string_literal: true

require "test_helper"

class AsyncDeliveryTest < Minitest::Test
  def teardown
    @delivery&.shutdown(0.5)
    super
  end

  def delivery(transport, **settings)
    @sleeper = RecordingSleeper.new
    @delivery = GoodSorcery::Delivery::Async.new(
      transport: transport, serializer: GoodSorcery::EventSerializer.new(captured_log), log: captured_log,
      sleeper: @sleeper, backoff: GoodSorcery::Delivery::Backoff.new(random: Random.new(1)),
      batch_size: 25, flush_interval: 5, max_queue_size: 100, **settings
    )
  end

  def event(id = SecureRandom.uuid)
    { "event_id" => id, "exception" => { "class" => "RuntimeError" } }
  end

  def test_sends_a_batch_as_soon_as_batch_size_events_are_queued
    transport = FakeTransport.new
    async = delivery(transport, batch_size: 3, flush_interval: 30)
    3.times { async.deliver(event) }

    assert(wait_until { transport.attempts == 1 })
    assert_equal 3, transport.batches.first.size
  end

  def test_sends_a_partial_batch_after_the_flush_interval
    transport = FakeTransport.new
    async = delivery(transport, batch_size: 25, flush_interval: 0.05)
    async.deliver(event)

    assert(wait_until { transport.attempts == 1 })
    assert_equal 1, transport.batches.first.size
  end

  def test_worker_thread_starts_lazily_and_is_named
    async = delivery(FakeTransport.new)

    refute_predicate async, :running?
    async.deliver(event)
    assert_predicate async, :running?
    assert(Thread.list.any? { |thread| thread.name == "goodsorcery-worker" })
  end

  def test_flush_waits_until_everything_is_delivered
    transport = FakeTransport.new
    async = delivery(transport, flush_interval: 30)
    ids = Array.new(5) { SecureRandom.uuid }
    ids.each { |id| async.deliver(event(id)) }

    assert async.flush(2)
    assert_equal ids, transport.delivered_ids
    assert_equal 0, async.queue_size
  end

  def test_drops_and_counts_events_when_the_queue_is_full
    gate = Queue.new
    transport = FakeTransport.new(gate: gate)
    async = delivery(transport, batch_size: 1, max_queue_size: 2, flush_interval: 30)
    async.deliver(event)
    assert(wait_until { async.queue_size == 1 && transport.attempts.zero? && gate.num_waiting == 1 })

    results = Array.new(4) { async.deliver(event) }
    gate.close

    assert_equal [true, true, false, false], results
    assert_equal 2, async.dropped_count
    assert_includes log_output, "queue full"
  end

  def test_retries_retryable_failures_with_backoff
    transport = FakeTransport.new(:retryable, :retryable)
    async = delivery(transport, max_retries: 3, flush_interval: 0.01)
    async.deliver(event("e1"))

    assert async.flush(2)
    assert_equal 3, transport.attempts
    assert_equal ["e1"], transport.delivered_ids
    assert_equal 2, @sleeper.pauses.size
    assert_operator @sleeper.pauses[1], :>, @sleeper.pauses[0] * 0.9
    assert(@sleeper.pauses.all? { |seconds| seconds.between?(0.5, 2.0) })
  end

  def test_gives_up_after_max_retries
    transport = FakeTransport.new(:retryable, :retryable, :retryable)
    async = delivery(transport, max_retries: 2, flush_interval: 0.01)
    async.deliver(event)

    assert async.flush(2)
    assert_equal 3, transport.attempts
    assert_empty transport.delivered_ids
    assert_includes log_output, "could not deliver 1 event(s) (HTTP 503); dropped"
  end

  def test_rate_limits_pause_for_retry_after_without_spending_retries
    transport = FakeTransport.new(:rate_limited, :rate_limited)
    async = delivery(transport, max_retries: 0, flush_interval: 0.01)
    async.deliver(event("kept"))

    assert async.flush(2)
    assert_equal [7, 7], @sleeper.pauses
    assert_equal ["kept"], transport.delivered_ids
  end

  def test_rejected_batches_are_not_retried
    transport = FakeTransport.new(:rejected)
    async = delivery(transport, flush_interval: 0.01)
    async.deliver(event)

    assert async.flush(2)
    assert_equal 1, transport.attempts
    assert_empty @sleeper.pauses
  end

  def test_worker_survives_transport_errors
    transport = FakeTransport.new(:raise)
    async = delivery(transport, flush_interval: 0.01)
    async.deliver(event("lost"))
    assert async.flush(2)
    async.deliver(event("sent"))

    assert async.flush(2)
    assert_equal ["sent"], transport.delivered_ids
    assert_includes log_output, "the delivery worker hit RuntimeError"
  end

  def test_shutdown_drains_the_queue_and_stops_the_worker
    transport = FakeTransport.new
    async = delivery(transport, flush_interval: 30)
    3.times { async.deliver(event) }

    assert async.shutdown(2)
    assert_equal 3, transport.delivered_ids.size
    refute_predicate async, :running?
  end

  def test_restarts_after_shutdown
    transport = FakeTransport.new
    async = delivery(transport, flush_interval: 0.01)
    async.shutdown(1)
    async.deliver(event("after"))

    assert async.flush(2)
    assert_equal ["after"], transport.delivered_ids
  end

  def test_forked_child_starts_a_fresh_queue_and_worker
    gate = Queue.new
    transport = FakeTransport.new(gate: gate)
    async = delivery(transport, flush_interval: 0.01, batch_size: 10)
    async.deliver(event("parent"))
    assert(wait_until { gate.num_waiting == 1 })
    parent_thread = async.instance_variable_get(:@thread)

    simulate_fork(async)
    async.deliver(event("child"))
    gate.close
    assert async.flush(2)

    refute_same parent_thread, async.instance_variable_get(:@thread)
    assert_equal ["child"], transport.delivered_ids
  end

  def test_real_fork_restarts_the_worker_in_the_child
    skip "fork is not available" unless Process.respond_to?(:fork)

    transport = FakeTransport.new
    async = delivery(transport, flush_interval: 0.01)
    async.deliver(event("parent"))
    async.flush(2)
    ids = in_forked_child do
      async.deliver(event("child"))
      async.flush(2)
      transport.delivered_ids
    end

    assert_equal %w[parent child], ids
  end

  def test_shutdown_is_a_no_op_before_any_event
    assert delivery(FakeTransport.new).shutdown(0.1)
  end

  private

  def in_forked_child
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      writer.write(JSON.generate(yield))
      writer.close
      exit!(0)
    end
    writer.close
    result = JSON.parse(reader.read)
    Process.wait(pid)
    result
  end

  # In a forked child only the forking thread survives, and Process.pid
  # differs from the pid the delivery recorded.
  def simulate_fork(async)
    async.instance_variable_get(:@thread).kill.join
    async.instance_variable_set(:@pid, Process.pid + 1)
  end
end

class EventQueueTest < Minitest::Test
  def test_pause_returns_early_when_closed
    queue = GoodSorcery::Delivery::EventQueue.new(max_size: 10, batch_size: 5)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Thread.new do
      sleep 0.05
      queue.close
    end
    queue.pause(5)

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
  end

  def test_take_batch_returns_empty_when_closed
    queue = GoodSorcery::Delivery::EventQueue.new(max_size: 10, batch_size: 5)
    queue.close

    assert_empty queue.take_batch(1)
    refute queue.push({})
  end
end
