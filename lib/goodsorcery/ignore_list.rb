# frozen_string_literal: true

module GoodSorcery
  # Exception classes that are never reported, by name; subclasses (any
  # ancestor with a listed name) are ignored too.
  class IgnoreList
    def initialize(entries)
      @names = Array(entries).to_h { |entry| [entry.is_a?(Module) ? entry.name : entry.to_s, true] }
    end

    def ignore?(exception)
      exception.class.ancestors.any? { |ancestor| @names.key?(ancestor.name.to_s) }
    end
  end
end
