# frozen_string_literal: true

module GoodSorcery
  # What is known about the current unit of work (a request, a job): context,
  # user, tags, transaction, request and breadcrumbs. Each thread (and fiber)
  # has its own scope. Hashes are replaced rather than mutated, so a saved
  # copy stays valid.
  class Scope
    STORAGE_KEY = :__goodsorcery_scope

    attr_reader :context, :tags, :breadcrumbs
    attr_accessor :user, :transaction, :request, :request_env

    def self.current
      Thread.current[STORAGE_KEY] ||= new
    end

    def self.current=(scope)
      Thread.current[STORAGE_KEY] = scope
    end

    def self.clear
      Thread.current[STORAGE_KEY] = nil
    end

    def initialize
      @context = {}
      @tags = {}
      @user = nil
      @breadcrumbs = Breadcrumbs.new
    end

    def merge_context(hash)
      @context = @context.merge(hash) if hash.is_a?(Hash)
      @context
    end

    # Merges +hash+ into the context for the duration of the block.
    def with_context(hash)
      previous = @context
      merge_context(hash)
      yield
    ensure
      @context = previous
    end

    def merge_tags(hash)
      @tags = @tags.merge(hash) if hash.is_a?(Hash)
      @tags
    end

    def add_breadcrumb(crumb, limit)
      @breadcrumbs.add(crumb, limit)
    end
  end

  # A ring buffer of the most recent breadcrumbs in a scope.
  class Breadcrumbs
    def initialize
      @items = []
    end

    def add(crumb, limit)
      @items << crumb
      @items.shift(@items.size - limit) if @items.size > limit
    end

    def to_a
      @items.dup
    end

    def size
      @items.size
    end

    def clear
      @items.clear
    end
  end
end
