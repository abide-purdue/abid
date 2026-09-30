require 'rack/unreloader'
require 'sinatra/base'
require 'sinatra/activerecord'

require_relative 'config/environment'

dev = Abid.env == 'development'
puts "Running in #{Abid.env} mode"

# `reolad:` was a typo, so the reloader ran with its default setting rather than
# the one intended here.
Unreloader = Rack::Unreloader.new(
  subclasses: %w[ActiveRecord::Migration ActiveModel::Validations ActiveModel::Model ActiveModel::Callbacks Sinatra::Base],
  reload: dev
) { App.new }

wd = File.dirname(__FILE__)

#watch the app file
Unreloader.require File.join(wd, 'app.rb')

# ApplicationRecord before any model that subclasses it. Alphabetical order
# only worked by luck until a model sorted ahead of "application_record".
Unreloader.require File.join(wd, 'models', 'application_record.rb')

[
  File.join(wd, 'models', '*.rb'),
  # '**' already covers the top level, so listing both loads every top-level
  # service twice and Ruby warns about re-initialised constants.
  File.join(wd, 'services', '**', '*.rb'),
  File.join(wd, 'views', '*.rb'),
  File.join(wd, 'views', 'components', '*.rb')
].each do |pattern|
  Dir.glob(pattern).sort.each { |file| Unreloader.require file }
end

# `Unreloader.require 'bot.rb'` used to be here. There is no bot.rb at the repo
# root, and pulling in bot/bot.rb would boot a second Discord gateway connection
# inside every web worker.

#reload app on model changes
Unreloader.record_dependency(File.join(wd, 'models'), 'app.rb')
Unreloader.record_dependency(File.join(wd, 'services'), 'app.rb')

#reload views on components changes
Unreloader.record_dependency(File.join(wd, 'views', 'components'), File.join(wd, 'views'))

app = dev ? Unreloader : App

use Rack::Protection::HostAuthorization, permitted_hosts: ["abidepurdue.com", "://abidepurdue.com"]

# Mounted under Abid.root_path when one is set. Rack::URLMap moves the prefix
# into SCRIPT_NAME, so every route stays `get '/board'`, every `redirect
# to(...)` and `url(...)` comes out prefixed, and a request outside the prefix
# is a 404 — nginx only forwards the prefix anyway.
if Abid.root_path.empty?
  run app
else
  map(Abid.root_path) { run app }
end
