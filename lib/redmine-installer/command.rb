require 'open3'

module RedmineInstaller
  class Command
    include Utils

    attr_reader :cmd, :title, :formatter

    def initialize(cmd, title: nil)
      @cmd = cmd
      @title = title || cmd
      @formatter = $SILENT_MODE ? SilentFormatter.new : FullFormatter.new
    end

    def run
      Bundler.with_unbundled_env do
        run!
      end
    end

    def run!
      success = false

      logger.std("--> #{cmd}")

      formatter.print_title(title)

      status = Open3.popen2e(cmd) do |input, output, wait_thr|
        input.close

        output.each_line do |line|
          logger.std(line)
          formatter.print_line(line)
        end

        wait_thr.value
      end

      success = status.success?
    rescue => e
      success = false
    ensure
      formatter.print_end(success)
    end


    class BaseFormatter
      include Utils
    end

    class FullFormatter < BaseFormatter

      def print_title(title)
        puts '-->'
        puts "--> #{pastel.yellow(title)}"
        puts '-->'
      end

      def print_line(line)
        puts line
      end

      def print_end(*)
      end

    end

    class SilentFormatter < BaseFormatter

      def initialize
        @output = ''
      end

      def print_title(title)
        format = "[#{pastel.yellow(':spinner')}] #{title}"
        @spinner = TTY::Spinner.new(format, success_mark: pastel.green('✔'), error_mark: pastel.red('✖'))
        @spinner.auto_spin
      end

      def print_line(line)
        @output << line
      end

      def print_end(success)
        if success
          @spinner.success
        else
          @spinner.error
          puts @output
        end
      end

    end

  end
end
