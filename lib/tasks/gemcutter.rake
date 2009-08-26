namespace :gemcutter do
  desc "Clean out files that aren't needed."
  task :clean => :environment do
    system("git clean -dfx server/; git checkout server/")
    [Rubygem, Version, Dependency, Requirement, Linkset].each { |c| c.delete_all }
    Rake::Task["gemcutter:index:create"].execute
  end

  desc "Get the gem server up and running"
  task :bootstrap => :environment do
    Rake::Task["gemcutter:clean"].execute
    Rake::Task["gemcutter:index:create"].execute
    ARGV[1] = "bench/old"
    Rake::Task["gemcutter:import:process"].execute
    ARGV[1] = "bench/new"
    Rake::Task["gemcutter:import:process"].execute
  end

  namespace :index do
    desc "Create the index"
    task :create => :environment do
      Gemcutter.indexer.generate_index
    end

    desc "Update the index"
    task :update => :environment do
      Gemcutter.indexer.update_index
    end

    desc "fix the index"
    task :reprocess => :environment do
      Rubygem.with_versions.each do |rubygem|
        rubygem.versions.each do |version|

          install = "#{rubygem.name}-#{version.number}"
          quick_path = "quick/Marshal.#{Gem.marshal_version}/#{install}.gemspec.rz"

          if VaultObject.exists?(quick_path)
            puts ">> Processing #{install}"
            spec = Marshal.load(Gem.inflate(VaultObject.value(quick_path)))
            version.description = spec.description
            version.summary = spec.summary
            version.number = spec.version.to_s

            platform = spec.original_platform
            platform = Gem::Platform::RUBY if platform.nil? or platform.empty?
            version.platform = platform
            version.save

            spec.development_dependencies.each { |dep| version.dependencies.create_from_gem_dependency!(dep) }
          else
            puts ">> BAD GEM: #{install}"
            version.update_attribute(:indexed, false)
          end
        end
      end

      specs = []
      latest_specs = []

      Rubygem.with_versions.each do |rubygem|
        current_version_number = rubygem.versions.current.number

        rubygem.versions.indexed.each do |version|
          latest_specs << version.to_index if version.number == current_version_number
          specs << version.to_index

          puts ">> latest specs: #{latest_specs.size}"
          puts ">>        specs: #{specs.size}"
        end
      end

      puts ">> ding, gems are done!"
      File.open("/tmp/latest_specs", "wb") { |f| f.write Marshal.dump(latest_specs) }
      File.open("/tmp/specs", "wb") { |f| f.write Marshal.dump(specs) }
    end
  end

  desc "Look for migrations and try to match the key"
  task :migrate => :environment do
    require 'webrat'
    require 'webrat/mechanize'

    Ownership.find_all_by_approved(false).each do |ownership|
      rubygem = ownership.rubygem
      project = rubygem.versions.current.rubyforge_project
      next if project.blank?

      puts ">> Checking ownership for #{ownership.user} under #{project}"

      begin
        session = Webrat::MechanizeSession.new
        session.visit("http://rubyforge.org/projects/#{project}")
        session.click_link("[News archive]")

        (session.current_dom / "#content a").each do |link|
          content = link.content.gsub(/[^a-z0-9]/, "")
          if content == ownership.token
            puts ">>> Success!"
            ownership.update_attribute(:approved, true)
          end
        end
      rescue Exception => e
        HoptoadNotifier.notify(:error_class => e.class, :error_message => e.message)
      end
    end
  end

  namespace :import do
    desc 'Download all of the gems in server/rubygems.txt'
    task :download do
      require 'curb'
      require 'active_support'
      url_queue = File.readlines("server/rubygems.txt").map { |g| g.strip }
      puts "Downloading #{url_queue.size} gems..."
      FileUtils.mkdir("cache") unless File.exist?("cache")

      responses = {}
      url_queue.in_groups_of(25).each do |group|
        multi = Curl::Multi.new
        group.each do |url|
          next unless url
          path = File.join("cache", File.basename(url))
          if File.exists?(path)
            puts "Skipping #{File.basename(url)}"
            next
          end

          easy = Curl::Easy.new(url) do |curl|
            curl.follow_location = true
            curl.on_success do |c|
              puts "Success for #{File.basename(url)} in #{c.total_time} seconds"
              begin
                File.open(path, "wb") do |file|
                  file.write c.body_str
                end
              rescue Exception => e
                puts "Problem saving: #{e}"
              end
            end
            curl.on_failure do |c|
              puts "Failure for #{File.basename(url)}: #{c.response_code}"
            end
          end
          multi.add(easy)
        end
        multi.perform
      end
    end

    desc 'Make sure all of the gems are on S3'
    task :verify => :environment do
      return unless Rails.env.production?
      Version.all.each do |version|
        path = "#{version.rubygem.name}-#{version.number}.gem"
        gem_path = "gems/#{path}"
        spec_path = "quick/Marshal.4.8/#{path}spec.rz"

        puts gem_path unless VaultObject.exists?(gem_path)
        puts spec_path unless VaultObject.exists?(spec_path)
      end
    end

    desc 'Upload gems to s3 like a boss'
    task :upload => :environment do
      return unless Rails.env.production?
      Version.all.each do |version|
        local_path = File.join(ARGV[1], "#{version.rubygem.name}-#{version.number}.gem")
        if File.exists?(local_path)
          puts "Processing #{local_path}"
          begin
            cutter = Gemcutter.new(nil, StringIO.new(File.open(local_path).read))
            cutter.pull_spec
            cutter.write
          rescue Exception => e
            puts "Problem uploading #{local_path}: #{e}"
          end
        else
          puts "Couldn't find #{local_path}"
        end
      end
    end

    desc 'Parse out rubygems'
    task :parse do
      require 'hpricot'
      doc = Hpricot(open("server/rubygems.html"))
      File.open("server/rubygems.txt", "w") do |file|
        (doc / "a")[1..-1].each do |gem|
          puts gem['href']
          file.write "http://gems.rubyforge.org/gems/#{gem['href']}\n"
        end
      end
    end

    desc 'Bring the gems through the gemcutter process'
    task :process => :environment do
      gems = Dir[File.join(ARGV[1], "*.gem")].sort.reverse
      puts "Processing #{gems.size} gems..."
      gems.each do |path|
        puts "Processing #{path}"
        cutter = Gemcutter.new(nil, StringIO.new(File.open(path).read))

        cutter.pull_spec and cutter.find and cutter.save
      end
    end

    desc 'Just create the index and save the gems in the db'
    task :indexify => :environment do
      gems = Dir[File.join(ARGV[1], "*.gem")].sort.reverse
      puts "Processing #{gems.size} gems..."
      source_index = Gem::SourceIndex.new

      gems.each do |path|
        puts "Processing #{path}"
        cutter = Gemcutter.new(nil, StringIO.new(File.open(path).read))

        begin
          cutter.pull_spec and cutter.find and cutter.build
          spec_path = File.join(ARGV[1], "#{cutter.rubygem.name}-#{cutter.rubygem.versions.last.to_s}.gem")

          if path == spec_path
            cutter.rubygem.save
            spec = cutter.spec
            Gemcutter.indexer.abbreviate spec
            Gemcutter.indexer.sanitize spec
            source_index.add_spec(spec, spec.original_name)
          else
            puts "Processed path (#{spec_path}) did not match: #{path}"
          end
        rescue Exception => e
          puts "Bad gem: #{e}"
        end
      end

      File.open(Gemcutter.server_path("source_index"), "wb") do |f|
        f.write Gem.deflate(Marshal.dump(source_index))
      end

      Gemcutter.indexer.update_index(source_index)
    end
  end

  desc 'Get the latest gems from rubyforge and index them here'
  task :update => :environment do
    return unless Rails.env.production?

    require 'open-uri'
    require 'rubygems/commands/list_command'

    ins = StringIO.new
    outs = StringIO.new
    Gem::DefaultUserInteraction.ui = Gem::StreamUI.new(ins, outs)
    Gem.sources = ["http://gems.rubyforge.org"]

    command = Gem::Commands::ListCommand.new
    command.options[:domain] = :remote
    command.options[:all] = true
    command.execute

    list = outs.string.split("\n")
    downloads = []
    list.each do |line|
      name, *versions = line.gsub(/[\(\),]/, "").split
      puts ">> Updating #{name}..."

      rubygem = Rubygem.find_by_name(name)
      if rubygem
        versions.each do |number|
          unless Version.exists?(:rubygem_id => rubygem.id, :number => number)
            downloads << "#{name}-#{number}.gem"
          end
        end
      else
        versions.each do |version|
          downloads << "#{name}-#{version}.gem"
        end
      end

    end

    downloads.each do |download|
      puts "Downloading #{download}..."
      begin
        cutter = Gemcutter.new(nil, StringIO.new(open("http://gems.rubyforge.org/gems/#{download}").read))
        cutter.pull_spec and cutter.find and cutter.build and cutter.save
      rescue Exception => e
        puts e.message
      end
    end
  end
end
