require 'find'

module RedmineInstaller
  class Redmine < TaskModule

    attr_reader :database
    attr_accessor :root

    REQUIRED_FILES = [
      'app',
      'lib',
      'config',
      'public',
      'db',
      'Gemfile',
      'Rakefile',
      'config.ru',
      File.join('lib', 'redmine'),
      File.join('lib', 'redmine.rb'),
    ]

    DEFAULT_BACKUP_ROOT = File.join(Dir.home, 'redmine-backups')
    BACKUP_EXCLUDE_FILES = ['log/', 'tmp/']

    CHECK_N_INACCESSIBLE_FILES = 10

    def initialize(task, root=nil)
      super(task)
      @root = root.to_s

      if (dump = task.options.database_dump)
        @database_dump_to_load = File.expand_path(dump)
      end
    end

    def database_yml_path
      File.join(root, 'config', 'database.yml')
    end

    def configuration_yml_path
      File.join(root, 'config', 'configuration.yml')
    end

    def files_path
      File.join(root, 'files')
    end

    def plugins_path
      File.join(root, 'plugins')
    end

    def easy_plugins_path
      File.join(plugins_path, 'easyproject', 'easy_plugins')
    end

    def log_path
      File.join(root, 'log')
    end

    def pids_files
      Dir.glob(File.join(root, 'tmp', 'pids', '*'))
    end

    def running?
      pids_files.any?
    end

    def load_profile(profile)
      @root = profile.redmine_root if root.empty?
      @backup_type = profile.backup_type
      @backup_root = profile.backup_root || profile.backup_dir

      # Convert setting from v1
      case @backup_type
      when :full_backup
        @backup_type = :full
      when :backup, :only_database
        @backup_type = :database
      end

      # Only valid setting
      unless [:full, :database, :nothing].include?(@backup_type)
        @backup_type = nil
      end
    end

    def save_profile(profile)
      profile.redmine_root = @root
      profile.backup_type = @backup_type
      profile.backup_root = @backup_root
    end

    # Ask for REDMINE_ROOT (if wasnt set) and check access rights
    #
    def ensure_and_valid_root
      if root.empty?
        puts
        @root = prompt.ask('Path to redmine root:', required: true, default: 'redmine')
      end

      @root = File.expand_path(@root)

      unless Dir.exist?(@root)
        create_dir(@root)
      end

      logger.info("REDMINE_ROOT: #{@root}")

      inaccessible_files = []

      Find.find(@root).each do |item|
        if !File.writable?(item) || !File.readable?(item)
          inaccessible_files << item
        end

        if inaccessible_files.size > CHECK_N_INACCESSIBLE_FILES
          break
        end
      end

      if inaccessible_files.any?
        error "Redmine root contains inaccessible files. Make sure that all files in #{@root} are readable/writeable for user #{env_user} (limit #{CHECK_N_INACCESSIBLE_FILES} files: #{inaccessible_files.join(', ')})"
      end
    end

    # Check if redmine is running based on PID files.
    #
    def check_running_state
      if running?
        if prompt.yes?("Your app is running based on PID files (#{pids_files.join(', ')}). Do you want continue?", default: false)
          logger.warn("App is running (pids: #{pids_files.join(', ')}). Ignore it and continue.")
        else
          error('App is running')
        end
      end
    end

    # Create and configure rails database
    #
    def create_database_yml
      print_title('Creating database configuration')

      @database = Database.create_config(self)
      logger.info("Database initialized #{@database}")
    end

    # Create and configure configuration
    # For now only email
    #
    def create_configuration_yml
      print_title('Creating email configuration')

      @configuration = Configuration.create_config(self)
      logger.info("Configuration initialized #{@configuration}")
    end

    # Run install commands (command might ask for additional informations)
    #
    def install
      print_title('Redmine installing')

      Dir.chdir(root) do
        # Gems can be locked on bad version
        FileUtils.rm_f('Gemfile.lock')

        # Install new gems
        bundle_install

        # Ensuring database
        rake_db_create

        # Load database dump (if was set via CLI)
        load_database_dump

        # Migrating
        rake_db_migrate

        # Plugin migrating
        rake_redmine_plugin_migrate

        # Generate secret token
        rake_generate_secret_token

        # Install easyproject
        rake_easyproject_install if easyproject?
      end
    end

    def upgrade
      print_title('Redmine upgrading')

      Dir.chdir(root) do
        # Gems can be locked on bad version
        FileUtils.rm_f('Gemfile.lock')

        # Install new gems
        bundle_install

        # Migrating
        rake_db_migrate

        # Plugin migrating
        rake_redmine_plugin_migrate

        # Generate secret token
        rake_generate_secret_token

        # Install easyproject
        rake_easyproject_install if easyproject?
      end
    end

    # # => ['.', '..']
    # def empty_root?
    #   Dir.entries(root).size <= 2
    # end

    def delete_root
      Dir.chdir(root) do
        Dir.entries('.').each do |entry|
          next if entry == '.' || entry == '..'
          FileUtils.remove_entry_secure(entry)
        end
      end

      logger.info("#{root} content was deleted")
    end

    def move_from(other_redmine)
      Dir.chdir(other_redmine.root) do
        Dir.entries('.').each do |entry|
          next if entry == '.' || entry == '..'
          FileUtils.mv(entry, root)
        end
      end

      logger.info("Copyied from #{other_redmine.root} into #{root}")
    end

    # Copy important files which cannot be deleted
    #
    def copy_importants_from(other_redmine)
      Dir.chdir(root) do
        # Copy database.yml
        FileUtils.cp(other_redmine.database_yml_path, database_yml_path)

        # Copy configuration.yml
        if File.exist?(other_redmine.configuration_yml_path)
          FileUtils.cp(other_redmine.configuration_yml_path, configuration_yml_path)
        end

        # Copy files
        FileUtils.cp_r(other_redmine.files_path, root)

        # Copy old logs
        FileUtils.mkdir_p(log_path)
        Dir.glob(File.join(other_redmine.log_path, 'redmine_installer_*')).each do |log|
          FileUtils.cp(log, log_path)
        end
      end

      # Copy 'keep' files (base on options)
      Array(task.options.keep).each do |path|
        origin_path = File.join(other_redmine.root, path)
        next unless File.exist?(origin_path)

        # Ensure folder
        target_dir = File.join(root, File.dirname(path))
        FileUtils.mkdir_p(target_dir)

        # Copy recursive
        FileUtils.cp_r(origin_path, target_dir)
      end

      logger.info('Important files was copyied')
    end

    # New package may not have all plugins
    #
    def copy_missing_plugins_from(other_redmine)
      # Copy missing redmine plugins
      Dir.chdir(other_redmine.plugins_path) do
        Dir.entries('.').each do |plugin|
          next if plugin == '.' || plugin == '..'

          # Plugin is not directory
          unless File.directory?(plugin)
            next
          end

          to = File.join(plugins_path, plugin)

          # Plugins does not exist
          unless Dir.exist?(to)
            FileUtils.cp_r(plugin, to)
          end
        end
      end

      # Copy missing client modification plugin
      if easyproject?
        old_modifications = Dir.glob(File.join(other_redmine.easy_plugins_path, 'modification_*'))
        old_modifications.each do |old_modification_path|
          next if !File.directory?(old_modification_path)

          basename = File.basename(old_modification_path)

          new_modification_path = File.join(easy_plugins_path, basename)
          next if File.exist?(new_modification_path)

          FileUtils.cp_r(old_modification_path, new_modification_path)
        end
      end
    end

    def validate
      # Check for required files
      Dir.chdir(root) do
        REQUIRED_FILES.each do |path|
          unless File.exist?(path)
            error "Redmine #{root} is not valid. Missing #{path}."
          end
        end
      end

      # Plugins are in right dir
      Dir.glob(File.join(root, 'vendor', 'plugins', '*')).each do |path|
        if File.directory?(path)
          error "Plugin should be on plugins dir. On vendor/plugins is #{path}"
        end
      end
    end

    # Backup:
    # - full redmine (except log, tmp)
    # - production database
    def make_backup
      print_title('Data backup')

      @backup_type ||= prompt.select('What type of backup do you want?',
        'Full (redmine root and database)' => :full,
        'Only database' => :database,
        'Nothing' => :nothing)

      logger.info("Backup type: #{@backup_type}")

      # Dangerous option
      if @backup_type == :nothing
        if prompt.yes?('Are you sure you dont want backup?', default: false)
          logger.info('Backup option nothing was confirmed')
          return
        else
          @backup_type = nil
          return make_backup
        end
      end

      @backup_root ||= prompt.ask('Where to save backup:', required: true, default: DEFAULT_BACKUP_ROOT)
      @backup_root = File.expand_path(@backup_root)

      @backup_dir = File.join(@backup_root, Time.now.strftime('backup_%d%m%Y_%H%M%S'))
      create_dir(@backup_dir)

      files_to_backup = []
      Dir.chdir(root) do
        case @backup_type
        when :full
          files_to_backup = Dir.glob(File.join('**', '{*,.*}'))
        end
      end

      if files_to_backup.any?
        files_to_backup.delete_if do |path|
          path.start_with?(*BACKUP_EXCLUDE_FILES)
        end

        @backup_package = File.join(@backup_dir, 'redmine.zip')

        Dir.chdir(root) do
          puts
          puts 'Files backuping'
          Zip::File.open(@backup_package, Zip::File::CREATE) do |zipfile|
            progressbar = TTY::ProgressBar.new(PROGRESSBAR_FORMAT, total: files_to_backup.size, frequency: 2, clear: true)

            files_to_backup.each do |entry|
              zipfile.add(entry, entry)
              progressbar.advance(1)
            end

            progressbar.finish
          end
        end

        puts "Files backed up on #{@backup_package}"
        logger.info('Files backed up')
      end

      @database = Database.init(self)
      @database.make_backup(@backup_dir)

      puts "Database backed up on #{@database.backup}"
      logger.info('Database backed up')
    end

    def valid_options
      if @database_dump_to_load && !File.exist?(@database_dump_to_load)
        error "Database dump #{@database_dump_to_load} does not exist (path is expanded)."
      end
    end

    def clean_up
    end

    private

      def bundle_install
        gemfile = File.join(root, 'Gemfile')
        
        if !Gem.available?('bundler')
          run_command("gem install bundler", 'Bundle install')
        end
        
        status = run_command("bundle install #{task.options.bundle_options} --gemfile #{gemfile}", 'Bundle install')

        # Even if bundle could not install all gem EXIT_SUCCESS is returned
        if !status || !File.exist?('Gemfile.lock')
          puts
          selected = prompt.select("Gemfile.lock wasn't created. Please choose one option:",
            'Try again' => :try_again,
            'Change bundle options' => :change_options,
            'Cancel' => :cancel)

          case selected
          when :try_again
            bundle_install
          when :change_options
            task.options.bundle_options = prompt.ask('New options:', default: task.options.bundle_options)
            bundle_install
          when :cancel
            error('Operation canceled by user')
          end
        end
      end

      def rake_db_create
        # Always return 0
        run_command('RAILS_ENV=production bundle exec rake db:create', 'Database creating')
      end

      def rake_db_migrate
        status = run_command('RAILS_ENV=production bundle exec rake db:migrate', 'Database migrating')

        unless status
          puts
          selected = prompt.select('Migration end with error. Please choose one option:',
            'Try again' => :try_again,
            'Create database first' => :create_database,
            'Change database configuration' => :change_configuration,
            'Cancel' => :cancel)

          case selected
          when :try_again
            rake_db_migrate
          when :create_database
            rake_db_create
            rake_db_migrate
          when :change_configuration
            create_database_yml
            rake_db_migrate
          when :cancel
            error('Operation canceled by user')
          end
        end
      end

      def rake_redmine_plugin_migrate
        status = run_command('RAILS_ENV=production bundle exec rake redmine:plugins:migrate', 'Plugins migration')

        unless status
          puts
          selected = prompt.select('Plugin migration end with error. Please choose one option:',
            'Try again' => :try_again,
            'Continue' => :continue,
            'Cancel' => :cancel)

          case selected
          when :try_again
            rake_redmine_plugin_migrate
          when :continue
            logger.warn('Plugin migration end with error but step was skipped.')
          when :cancel
            error('Operation canceled by user')
          end
        end
      end

      def rake_generate_secret_token
        status = run_command('RAILS_ENV=production bundle exec rake generate_secret_token', 'Generating secret token')

        unless status
          puts
          selected = prompt.select('Secret token could not be created. Please choose one option:',
            'Try again' => :try_again,
            'Continue' => :continue,
            'Cancel' => :cancel)

          case selected
          when :try_again
            rake_generate_secret_token
          when :continue
            logger.warn('Secret token could not be created but step was skipped.')
          when :cancel
            error('Operation canceled by user')
          end
        end
      end

      def rake_easyproject_install
        status = run_command('RAILS_ENV=production bundle exec rake easyproject:install', 'Installing easyproject')

        unless status
          puts
          selected = prompt.select('Easyproject could not be installed. Please choose one option:',
            'Try again' => :try_again,
            'Cancel' => :cancel)

          case selected
          when :try_again
            rake_easyproject_install
          when :cancel
            error('Operation canceled by user')
          end
        end
      end

      def easyproject?
        Dir.entries(plugins_path).include?('easyproject')
      end

      def load_database_dump
        return if @database_dump_to_load.nil?

        selected = prompt.select('Database dump will be loaded. Before that all data must be destroy.',
          'Skip dump loading' => :cancel,
          'I am aware of this. Want to continue' => :continue)

        if selected == :continue
          @database.do_restore(@database_dump_to_load)
          logger.info('Database dump was loaded.')
        else
          logger.info('Database dump loading was skipped.')
        end
      end

  end
end
