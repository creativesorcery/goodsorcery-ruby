# frozen_string_literal: true

module GoodSorcery
  module Performance
    # A short name for the current process, from its title: "Puma worker 3",
    # "Puma", "Sidekiq", else the program's basename. Nothing else from the
    # command line is used (it can carry arguments).
    module ProcessLabel
      MAX_LENGTH = 255

      def self.current(title = $PROGRAM_NAME)
        text = title.to_s
        worker = text[/\Apuma: cluster worker (\d+)/, 1]
        return "Puma worker #{worker}" if worker
        return "Puma" if text.start_with?("puma")
        return "Sidekiq" if text.start_with?("sidekiq")

        Text.limit(File.basename(text.split.first.to_s), MAX_LENGTH)
      end
    end
  end
end
