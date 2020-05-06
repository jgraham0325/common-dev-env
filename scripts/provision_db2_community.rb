require_relative 'utilities'
require_relative 'commodities'
require 'yaml'

def provision_db2_community(root_loc, new_containers)
  puts colorize_lightblue('Searching for db2_community initialisation SQL in the apps')

  # Load configuration.yml into a Hash
  config = YAML.load_file("#{root_loc}/dev-env-config/configuration.yml")
  return unless config['applications']

  config['applications'].each do |appname, _appconfig|
    # To help enforce the accuracy of the app's dependency file, only search for init sql
    # if the app specifically specifies db2_community in it's commodity list
    next unless File.exist?("#{root_loc}/apps/#{appname}/configuration.yml")
    next unless commodity_required?(root_loc, appname, 'db2_community')

    # Load any SQL or shell script contained in the apps into the docker commands list
    if process_fragments?(appname, root_loc, new_db_container)
      new_db_container = new_db_container?(new_containers)
      process_db2_community_fragments(root_loc, appname, new_db_container)
    else
      puts colorize_yellow("#{appname} says it uses DB2 Community but doesn't contain an init SQL or shell script file.
          Oh well, onwards we go!")
    end
  end
end

def process_fragments?(appname, root_loc, new_db_container)
  return false if Dir.glob("#{root_loc}/apps/#{appname}/fragments/db2-community-init-fragment.*").empty?
  return false if commodity_provisioned?(root_loc, appname, 'db2_community') && !new_db_container

  true
end

def new_db_container?(new_containers)
  if new_containers.include?('db2_community')
    puts colorize_yellow('The DB2 Community container has been newly created - '\
                         'provision status in .commodities will be ignored')
    true
  else
    false
  end
end

def process_db2_community_fragments(root_loc, appname)
  puts colorize_pink("Found some in #{appname}")
  init_db2_community

  begin
    sql_path = "#{root_loc}/apps/#{appname}/fragments/db2-community-init-fragment.sql"
    shell_script_path = "#{root_loc}/apps/#{appname}/fragments/db2-community-init-fragment.sh"

    init_db2_community_sql(sql_path, appname) if File.exist?(sql_path)
    init_db2_community_shell_script(shell_script_path, appname) if File.exist?(shell_script_path)

    set_commodity_provision_status(root_loc, appname, 'db2_community', true)
  rescue StandardError => e
    puts colorize_red("#{e.class}: #{e.message}")
    puts colorize_red(e.backtrace.join("\n"))
    set_commodity_provision_status(root_loc, appname, 'db2_community', false)
  end
end

def init_db2_community
  # Start DB2 Community
  run_command('docker-compose up -d db2_community')

  # Better not run anything until DB2 is ready to accept connections...
  puts colorize_lightblue('Waiting for DB2 Community to finish initialising (this will take a few minutes)')
  command_output = []
  command_outcode = 1
  until command_outcode.zero? && check_healthy_output(command_output)
    command_output.clear
    command_outcode = run_command('docker inspect --format="{{json .State.Health.Status}}" db2_community',
                                  command_output)
    puts colorize_yellow('DB2 Community is unavailable - sleeping')
    sleep(5)
  end
  puts colorize_green('DB2 Community is ready')
  # One more sleep to ensure user gets set up
  sleep(7)
end

def init_db2_community_sql(script_full_path, appname)
  insert_file_into_db2_docker_container(script_full_path)

  file_name = File.basename(script_full_path)

  puts colorize_lightblue("Running #{file_name} for #{appname}")

  exit_code = run_command("docker exec -u db2inst1 db2_community bash -c \"~/sqllib/bin/db2 -tvf /#{file_name}\"")

  disconnect_all_open_db2_connections

  puts colorize_lightblue("Completed #{appname} table sql fragment")

  if ![0, 2, 4, 6].include?(exit_code)
    # if exit_code != 6 && exit_code != 0 && exit_code != 2 && exit_code != 4
    puts colorize_red("Something went wrong with the table setup. Exitcode - #{exit_code}")
    raise "Failed to run init sql for #{appname}"
  else
    puts colorize_yellow("Database(s) and Table(s) created correctly. Exitcode - #{exit_code}.\n" \
                         'Exit code 4 tends to mean Database already exists. 6 - table already exists. 2 - ' \
                         "index already exists\n" \
                         'If in doubt read the above output carefully for the exact reason')

  end
end

def init_db2_community_shell_script(script_full_path, appname)
  insert_file_into_db2_docker_container(script_full_path)

  file_name = File.basename(script_full_path)

  puts colorize_lightblue("Running #{file_name} for #{appname}")

  exit_code = run_command("docker exec -u db2inst1 db2_community bash -c \"./#{file_name}\"")

  disconnect_all_open_db2_connections

  puts colorize_lightblue("Completed #{appname} shell script fragment")

  if exit_code != 0
    puts colorize_red("Something went wrong with the shell script setup. Exitcode - #{exit_code}")
    raise "Failed to run init shell script for #{appname}"
  else
    puts colorize_yellow("Shell script run correctly. Exit code - #{exit_code}.")
  end
end

def insert_file_into_db2_docker_container(host_path)
  # See comments in provision_postgres.rb for why we are doing it this way
  host_directory = File.dirname(host_path)
  file_name = File.basename(host_path)

  run_command("tar -c -C #{host_directory} #{file_name} | docker cp - db2_community:/")
  run_command("docker exec db2_community bash -c 'chmod o+rx /#{file_name}'")
end

def disconnect_all_open_db2_connections
  # Just in case a fragment hasn't disconnected from it's DB, let's do it now so the next fragment doesn't fail
  # when doing it's CONNECT TO
  run_command('docker exec -u db2inst1 db2_community bash -c "~/sqllib/bin/db2 disconnect all"')
end
