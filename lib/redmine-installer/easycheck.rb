require 'open3'

module RedmineInstaller
  class Easycheck
    extend Utils

    EASYCHECK_SH = 'https://raw.githubusercontent.com/easyredmine/easy_server_requirements_check/master/easycheck.sh'

    def self.run
      Bundler.with_unbundled_env do
        if Kernel.system('which', 'wget')
          Open3.pipeline(['wget', EASYCHECK_SH, '-O', '-', '--quiet'], 'bash')

        elsif Kernel.system('which', 'curl')
          Open3.pipeline(['curl', EASYCHECK_SH, '--output', '-', '--silent'], 'bash')

        else
          error 'Neither wget nor curl was found'
        end
      end

      puts
      if !prompt.yes?('Continue?')
        error 'Canceled'
      end
    end

  end
end
