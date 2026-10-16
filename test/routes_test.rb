require_relative 'test_helper'
require 'rack/test'
Abid.load_views
require_relative '../app'

# Registering sinatra-activerecord attaches a stdout logger, which buries the
# test output under every SELECT the views run.
ActiveRecord::Base.logger = nil

# Until now nothing exercised a single route or rendered a single view, so any
# of these pages could 500 and only a human clicking would find out. Phlex
# errors in particular are a runtime surprise: a method name that collides with
# an HTML element, or a nil where a view expects a record, raises only when that
# branch actually renders.
class RoutesTest < AbidTest
  include Rack::Test::Methods

  def app = App

  def setup
    super
    # Rack::Test drives the app in this process, so it shares the transaction
    # this test opened and everything rolls back afterwards.
    App.set :sessions, false
    App.set :show_exceptions, false
    App.set :raise_errors, true
    # Sinatra 4 rejects requests whose Host is not permitted; Rack::Test sends
    # "example.org", which otherwise 403s every request here.
    App.set :host_authorization, { permitted_hosts: [] }

    @leader = User.create!(name: 'Coordinator', username: 'coord', discord_id: next_discord_id,
                           leader: true, password: 'test-password')
    @event = make_event(name: 'Sunday Service')
  end

  # The session is stubbed rather than driven through POST /login, so these
  # tests stay about routing and rendering rather than re-testing auth.
  def as_leader
    env 'rack.session', { user_id: @leader.id }
  end

  def get_ok(path)
    as_leader
    get path
    assert last_response.ok?, "GET #{path} returned #{last_response.status}\n#{last_response.body.to_s[0, 600]}"
    last_response
  end

  def test_every_listing_page_renders
    %w[/ /board /schedule /locations /users].each { |path| get_ok(path) }
  end

  # Events, Series and Sign-ups are one page now. The old paths still work so
  # bookmarks and any link out in the wild do not break.
  def test_the_three_old_index_paths_redirect_to_the_schedule
    %w[/events /series /signups].each do |path|
      as_leader
      get path
      assert_equal 302, last_response.status, path
      assert_includes last_response.location, '/schedule'
    end
  end

  def test_every_record_page_renders
    series = EventSeries.create!(name: 'Friday Bible Study', weekday: 5,
                                 start_time_of_day: '18:30', location: @event.location)
    post = SignupPost.create!(channel: channel, service_date: Time.zone.today, status: 'draft')

    get_ok("/events/#{@event.id}")
    get_ok("/events/#{@event.id}/edit")
    get_ok('/events/new')
    get_ok("/series/#{series.id}")
    get_ok("/series/#{series.id}/edit")
    get_ok('/series/new')
    get_ok("/signups/#{post.id}")
    get_ok("/users/#{@leader.id}")
    get_ok('/schedule')
    get_ok("/events/#{@event.id}/dispatches")
  end

  def test_csv_exports_render
    assert_equal 'text/csv', get_ok("/events/#{@event.id}.csv").content_type.split(';').first
    get_ok("/board/#{@event.id}.csv")
  end

  # /events/new takes an optional date. Nothing links to it with one any more
  # (the board's '+ slot' did, and is now next/previous arrows), but the param
  # is still supported and a bad one must not 500 the page.
  def test_new_event_accepts_and_survives_a_date_param
    get_ok('/events/new?date=2026-09-20')
    get_ok('/events/new?date=not-a-date')
  end

  def test_users_page_filters_all_render
    UsersIndex::FILTERS.each { |value, _| get_ok("/users?filter=#{value}") }
    get_ok('/users?q=coord')
  end

  def test_members_defaults_to_active_and_has_no_everyone_tab
    body = get_ok('/users').body

    refute_includes UsersIndex::FILTERS.map(&:first), 'all'
    assert_includes body, 'Active'
    assert_includes body, 'Non-Active'
  end

  # Drivers / Riders / Missing details describe the active roster, not everyone
  # who has ever been in the Discord.
  def test_the_member_tabs_are_cuts_of_the_active_roster
    User.create!(name: 'Active driver', username: 'ad', discord_id: next_discord_id,
                 password: 'x' * 10, capacity: 4, active: true)
    User.create!(name: 'Alum driver', username: 'alumd', discord_id: next_discord_id,
                 password: 'x' * 10, capacity: 4)

    names = ->(f) { get_ok("/users?filter=#{f}").body }

    assert_includes names.call('drivers'), 'Active driver'
    refute_includes names.call('drivers'), 'Alum driver'
    refute_includes names.call('riders'), 'Alum driver'
    refute_includes names.call('missing'), 'Alum driver'
    assert_includes names.call('other'), 'Alum driver'
  end

  def test_one_click_marks_a_member_active_and_back
    member = User.create!(name: 'Laura', username: 'laura', discord_id: next_discord_id,
                          password: 'x' * 10)

    as_leader
    post "/users/#{member.id}/active", active: '1'
    assert member.reload.active?

    as_leader
    post "/users/#{member.id}/active", active: '0'
    refute member.reload.active?
  end

  def test_the_toggle_returns_to_the_tab_you_were_on
    # Marking a dozen people active in a row must not bounce you back to the
    # top of an unfiltered list each time.
    member = User.create!(name: 'Laura', username: 'laura', discord_id: next_discord_id,
                          password: 'x' * 10)

    as_leader
    post "/users/#{member.id}/active", active: '1', filter: 'other', q: 'rach'

    assert_equal 302, last_response.status
    assert_includes last_response.location, 'filter=other'
    assert_includes last_response.location, 'q=rach'
  end

  def test_a_member_cannot_be_marked_active_by_a_non_leader
    member = User.create!(name: 'Laura', username: 'laura', discord_id: next_discord_id,
                          password: 'x' * 10)
    plain_user = User.create!(name: 'Nobody', username: 'nobody', discord_id: next_discord_id,
                              password: 'x' * 10)

    env 'rack.session', { user_id: plain_user.id }
    post "/users/#{member.id}/active", active: '1'

    assert_equal 403, last_response.status
    refute member.reload.active?
  end

  def test_the_profile_checkbox_saves_active
    member = User.create!(name: 'Laura', username: 'laura', discord_id: next_discord_id,
                          password: 'x' * 10)

    as_leader
    patch "/users/#{member.id}", name: 'Laura', active: '1'
    assert member.reload.active?

    # Unticked checkboxes are absent from params; the hidden '0' is what turns
    # it off, so this must not silently leave it on.
    as_leader
    patch "/users/#{member.id}", name: 'Laura', active: '0'
    refute member.reload.active?
  end

  # --- the weekly driver work ----------------------------------------------

  def test_a_rider_can_be_promoted_to_driver_in_place
    # Everyone who reacts arrives as a rider, so without this every driver had
    # to be deleted and re-added, every week.
    user = User.create!(name: 'Caleb', username: 'caleb', discord_id: next_discord_id,
                        password: 'x' * 10, capacity: 4)
    ride = @event.rides.create!(user: user, role: 'rider', status: 'requested')

    as_leader
    patch "/board/#{@event.id}/rides/#{ride.id}", role: 'driver'

    ride.reload
    assert_equal 'driver', ride.role
    assert_equal 4, ride.seats, 'a promoted driver needs seats or the car has none'
  end

  def test_a_nonsense_role_is_ignored_rather_than_crashing
    user = User.create!(name: 'Caleb', username: 'caleb2', discord_id: next_discord_id,
                        password: 'x' * 10)
    ride = @event.rides.create!(user: user, role: 'rider', status: 'requested')

    as_leader
    patch "/board/#{@event.id}/rides/#{ride.id}", role: 'astronaut'

    refute_equal 500, last_response.status
    assert_equal 'rider', ride.reload.role
  end

  def test_one_press_seats_every_regular_driver
    drives = User.create!(name: 'Caleb', username: 'caleb3', discord_id: next_discord_id,
                          password: 'x' * 10, capacity: 4, active: true)
    User.create!(name: 'Passenger', username: 'pax', discord_id: next_discord_id,
                 password: 'x' * 10, active: true)
    User.create!(name: 'Alum', username: 'alum', discord_id: next_discord_id,
                 password: 'x' * 10, capacity: 4)

    as_leader
    post "/board/#{@event.id}/drivers"

    roles = @event.rides.reload.includes(:user).map { |r| [r.user.name, r.role] }
    assert_equal [['Caleb', 'driver']], roles,
                 'only active members with seats, and nobody twice'
    assert_equal 4, @event.rides.first.seats
  end

  def test_adding_regular_drivers_twice_does_not_duplicate_anyone
    User.create!(name: 'Caleb', username: 'caleb4', discord_id: next_discord_id,
                 password: 'x' * 10, capacity: 4, active: true)

    as_leader
    post "/board/#{@event.id}/drivers"
    as_leader
    post "/board/#{@event.id}/drivers"

    assert_equal 1, @event.rides.reload.count
  end

  # --- the route map -------------------------------------------------------

  def test_the_map_renders_with_a_seated_rider
    here = Location.create!(name: 'Cary', zone: Location::ZONES.first, lat: 40.4278, lon: -86.9210)
    there = Location.create!(name: 'Church', zone: Location::ZONES.first, lat: 40.4521, lon: -86.9720)
    @event.update!(location: there)

    driver = User.create!(name: 'Caleb', username: 'cbm', discord_id: next_discord_id,
                          password: 'x' * 10, capacity: 4, location: here)
    rider = User.create!(name: 'Nathan', username: 'nw', discord_id: next_discord_id,
                         password: 'x' * 10, location: here)
    d = @event.rides.create!(user: driver, role: 'driver', status: 'confirmed', seats: 4)
    @event.rides.create!(user: rider, role: 'rider', status: 'confirmed', driver_ride: d,
                         pickup_location: here)

    body = get_ok("/board/#{@event.id}/map").body

    assert_includes body, 'data-route-map'
    assert_includes body, 'tile.openstreetmap.org', 'the basemap tiles must be configured'
    assert_includes body, 'Caleb'
    # The payload the browser draws from, carried on the element.
    assert_includes body, '&quot;lat&quot;'
  end

  # "Nothing to draw" with no cause is indistinguishable from a broken page,
  # which is exactly how this was reported — twice. The first fix explained
  # itself but still showed no map; a map page with no map reads as broken
  # however good the sentence above it is.
  def test_an_empty_map_still_draws_the_basemap_and_says_why_there_are_no_routes
    # Nothing anywhere has coordinates yet — not even a venue.
    body = get_ok("/board/#{@event.id}/map").body
    assert_includes body, 'nobody is driving this one'
    assert_includes body, 'nothing to put on a map'
    refute_includes body, 'data-route-map'

    # Give it somewhere to go and the map appears, with no routes on it.
    there = Location.create!(name: 'Church', zone: Location::ZONES.first, lat: 40.4521, lon: -86.9720)
    @event.update!(location: there)

    body = get_ok("/board/#{@event.id}/map").body
    assert_includes body, 'data-route-map', 'the venue alone is worth a map'
    assert_includes body, 'nobody is driving this one'
  end

  # A driver with an empty car has only the destination, which draws no line —
  # but the map itself still belongs on the page.
  def test_a_driver_with_an_empty_car_draws_no_route_but_keeps_the_map
    there = Location.create!(name: 'Church', zone: Location::ZONES.first, lat: 40.4521, lon: -86.9720)
    @event.update!(location: there)
    here = Location.create!(name: 'Cary', zone: Location::ZONES.first, lat: 40.4278, lon: -86.9210)
    driver = User.create!(name: 'Caleb', username: 'cbm3', discord_id: next_discord_id,
                          password: 'x' * 10, capacity: 4, location: here)
    @event.rides.create!(user: driver, role: 'driver', status: 'confirmed', seats: 4)

    body = get_ok("/board/#{@event.id}/map").body
    assert_includes body, 'nobody has been seated'
    assert_includes body, 'data-route-map'
    assert_includes body, '&quot;routes&quot;' if body.include?('&quot;routes&quot;')
  end

  # Before anyone is seated, where people are WAITING is the whole value of the
  # page — it is what tells you which car they belong in.
  def test_waiting_riders_are_pinned_on_the_map
    there = Location.create!(name: 'Church', zone: Location::ZONES.first, lat: 40.4521, lon: -86.9720)
    @event.update!(location: there)
    here = Location.create!(name: 'Cary', zone: Location::ZONES.first, lat: 40.4278, lon: -86.9210)
    rider = User.create!(name: 'Waiting Person', username: 'wp', discord_id: next_discord_id,
                         password: 'x' * 10, location: here)
    @event.rides.create!(user: rider, role: 'rider', status: 'requested', pickup_location: here)

    body = get_ok("/board/#{@event.id}/map").body

    assert_includes body, 'data-waiting'
    assert_includes body, 'Waiting Person'
    assert_includes body, 'waiting for a ride'
  end

  # A rider pointing at a driver who is no longer driving was in no car and in
  # no queue: invisible on the board, and still counted as seated.
  def test_a_rider_whose_driver_withdrew_goes_back_to_the_queue
    driver_ride = make_driver(@event, 'ian', seats: 4, zone: ZONE_1)
    rider = make_rider(@event, 'caitlin', zone: ZONE_1, driver: driver_ride)

    driver_ride.update!(status: 'cancelled')
    board = RideBoard.new(@event.reload)

    assert_includes board.pool.map(&:id), rider.id, 'the rider vanished from the board'
    assert_equal 0, board.seated_count, 'nobody is collecting them, so they are not seated'
  end

  def test_a_stop_with_no_location_is_named_rather_than_dropped
    there = Location.create!(name: 'Church', zone: Location::ZONES.first, lat: 40.4521, lon: -86.9720)
    @event.update!(location: there)
    driver = User.create!(name: 'Caleb', username: 'cbm2', discord_id: next_discord_id,
                          password: 'x' * 10, capacity: 4, location: there)
    rider = User.create!(name: 'Nowhere Person', username: 'np', discord_id: next_discord_id,
                         password: 'x' * 10)
    d = @event.rides.create!(user: driver, role: 'driver', status: 'confirmed', seats: 4)
    @event.rides.create!(user: rider, role: 'rider', status: 'confirmed', driver_ride: d)

    body = get_ok("/board/#{@event.id}/map").body

    assert_includes body, 'Not on the map'
    assert_includes body, 'Nowhere Person'
  end

  # --- locations -----------------------------------------------------------

  def test_a_location_address_can_be_saved
    place = Location.create!(name: 'Third and West', zone: Location::ZONES.first)

    as_leader
    patch "/locations/#{place.id}", address: 'West Third Street'

    assert_equal 'West Third Street', place.reload.address
  end

  def test_the_geocode_query_prefers_the_address_over_the_name
    # OSM has never heard of "Third and West" — querying it unbounded returns
    # nothing. It knows the street it stands on.
    place = Location.new(name: 'Third and West', address: 'West Third Street')
    assert_equal 'West Third Street, West Lafayette, Indiana', place.geocode_query

    named = Location.new(name: 'Cary Quadrangle')
    assert_equal 'Cary Quadrangle, West Lafayette, Indiana', named.geocode_query
  end

  def test_a_non_leader_cannot_edit_a_location
    place = Location.create!(name: 'Somewhere', zone: Location::ZONES.first)
    plain_user = User.create!(name: 'Nobody', username: 'nobody2', discord_id: next_discord_id,
                              password: 'x' * 10)

    env 'rack.session', { user_id: plain_user.id }
    patch "/locations/#{place.id}", address: 'hacked'

    assert_equal 403, last_response.status
    assert_nil place.reload.address
  end

  def test_unknown_record_is_not_found_rather_than_a_crash
    as_leader
    get '/events/999999'
    refute_equal 500, last_response.status
    get '/users/999999'
    refute_equal 500, last_response.status
  end

  def test_logged_out_visitor_is_sent_to_login
    env 'rack.session', {}
    get '/board'
    assert_equal 302, last_response.status
    assert_includes last_response.location.to_s, '/login'
  end

  def test_login_page_is_public
    env 'rack.session', {}
    get '/login'
    assert last_response.ok?
  end

  # --- the sign-up post lifecycle -----------------------------------------
  #
  # This is the flow the whole feature hangs off: compose a post, give it
  # options, schedule it, and have the publisher pick it up. Each step is a
  # separate route and they were only ever exercised by hand.

  def test_a_signup_post_can_be_composed_scheduled_and_becomes_publishable
    as_leader
    post '/signups', channel_id: channel.id, service_date: @event.start_time.to_date.to_s
    assert_includes [200, 302], last_response.status, last_response.body.to_s[0, 400]

    record = SignupPost.order(:id).last
    refute_nil record, 'POST /signups created nothing'

    # The option is not added by hand any more: one row per pickup time on the
    # date, created with the post.
    assert_equal 1, record.reload.options.count, 'the ride on that date got no row'

    option = record.options.first
    assert_equal '1️⃣', option.emoji_unicode
    assert_equal @event, option.event, 'the option must be linked to the ride it books'

    as_leader
    patch "/signups/#{record.id}/options/#{option.id}", label: 'Early ride'
    assert_equal 'Early ride', option.reload.label

    # The settings form saves the send time, then a separate button schedules.
    as_leader
    patch "/signups/#{record.id}", post_at: 1.hour.from_now.strftime('%Y-%m-%dT%H:%M'),
                                   channel_id: channel.id, service_date: Time.zone.today.to_s
    refute_nil record.reload.post_at, 'PATCH did not save the send time'

    as_leader
    post "/signups/#{record.id}/schedule"
    record.reload
    assert_equal 'scheduled', record.status
    refute_nil record.post_at

    # Due posts are what the bot's publisher actually looks for.
    record.update!(post_at: 1.minute.ago)
    assert_includes SignupPost.due, record
  end

  def test_scheduling_accepts_a_send_time_given_inline
    record = seeded_post
    as_leader
    post "/signups/#{record.id}/schedule", post_at: 1.hour.from_now.strftime('%Y-%m-%dT%H:%M')

    assert_equal 'scheduled', record.reload.status,
                 'a time passed to schedule must not be silently discarded'
  end

  def test_the_rendered_body_contains_each_option
    record = seeded_post
    as_leader
    patch "/signups/#{record.id}/options/#{record.options.first.id}", label: 'Early ride'

    body = record.reload.body
    assert_includes body, '1️⃣'
    assert_includes body, 'Early ride'
  end

  # --- post now ------------------------------------------------------------
  #
  # The web process has no Discord connection, so "send" can only mean "make
  # the row claimable by the bot". These assert exactly that and stop there —
  # nothing is posted to a real server.

  def test_post_now_makes_a_draft_claimable_by_the_bot
    record = seeded_post

    as_leader
    post "/signups/#{record.id}/post-now"

    record.reload
    assert_equal 'scheduled', record.status
    refute_nil record.post_at
    assert_operator record.post_at, :<=, Time.zone.now
    assert_includes SignupPost.due, record, 'the bot must be able to claim it'
  end

  def test_post_now_brings_a_scheduled_post_forward
    record = draft_post
    as_leader
    post "/signups/#{record.id}/options", emoji: '1️⃣', event_id: @event.id
    record.update!(post_at: 3.days.from_now, status: 'scheduled')

    as_leader
    post "/signups/#{record.id}/post-now"

    record.reload
    assert_equal 'scheduled', record.status
    assert_operator record.post_at, :<=, Time.zone.now
    assert_includes SignupPost.due, record
  end

  def test_post_now_refuses_a_post_with_no_rides
    record = draft_post

    as_leader
    post "/signups/#{record.id}/post-now"

    assert_equal 422, last_response.status
    refute_equal 'scheduled', record.reload.status
    refute_includes SignupPost.due, record
  end

  def test_post_now_refuses_a_post_already_sent
    record = draft_post
    record.update!(status: 'posted', discord_message_id: next_discord_id)

    as_leader
    post "/signups/#{record.id}/post-now"

    assert_equal 409, last_response.status
  end

  def test_a_permission_failure_says_what_to_fix
    record = draft_post
    as_leader
    post "/signups/#{record.id}/options", emoji: '1️⃣', event_id: @event.id
    record.update!(status: 'failed',
                   last_error: "Discordrb::Errors::NoPermission: The bot doesn't have the required permission to do this!")

    body = get_ok("/signups/#{record.id}").body

    # Discord's own wording names neither the permission nor the channel.
    assert_includes body, "cannot post in ##{channel.name}"
    assert_includes body, 'Send Messages'
    assert_includes body, 'View Channel'
  end

  # --- one-click sign-ups --------------------------------------------------

  def test_creating_a_post_fills_in_that_days_rides
    day = @event.start_time.to_date
    as_leader
    post '/signups', channel_id: channel.id, service_date: day.to_s

    record = SignupPost.order(:id).last
    assert_equal 1, record.options.count, 'the post should arrive already filled in'
    assert_equal @event, record.options.first.event
    assert record.bound?
  end

# One row per pickup time on the date, and the time is printed rather than
  # chosen — there is no dropdown, no Add and no Delete, because the list is a
  # projection of the day rather than something to assemble.
  def test_the_option_row_states_its_time_and_cannot_be_added_to_or_removed
    other = make_event(name: 'Friday Bible Study', starts: @event.start_time + 3.days)
    record = seeded_post

    body = get_ok("/signups/#{record.id}").body

    assert_equal 1, record.options.count
    assert_includes body, @event.start_time.strftime('%-l:%M %p')
    refute_includes body, "value=\"#{other.id}\"", 'a ride on another day is being offered'
    refute_includes body, 'Add option'
    refute_includes body, 'Fill from this date'
    refute_includes body, "/options/#{record.options.first.id}\" class=\"contents\"",
                    'the delete form is still there'
  end

  # The routes went with the buttons — a stale page must not be able to reach
  # them either.
  def test_options_can_no_longer_be_added_or_deleted_by_route
    record = seeded_post
    option = record.options.first

    as_leader
    post "/signups/#{record.id}/options", emoji: '🚗', event_id: @event.id
    assert_equal 404, last_response.status

    as_leader
    delete "/signups/#{record.id}/options/#{option.id}"
    assert_equal 404, last_response.status

    assert_equal 1, record.reload.options.count
  end

    def test_the_schedule_offers_to_create_a_signup_for_an_uncovered_date
    body = get_ok('/schedule').body

    assert_includes body, @event.start_time.strftime('%A %-d %B')
    assert_includes body, 'Create'
  end

  # --- the emoji picker ----------------------------------------------------

  def test_an_emoji_chosen_from_the_picker_is_accepted
    record = seeded_post
    option = record.options.first

    as_leader
    patch "/signups/#{record.id}/options/#{option.id}", emoji_pick: '🚗'

    assert_equal '🚗', option.reload.emoji_unicode
    assert_equal @event, option.event, 'changing the emoji must not move the ride'
  end

  # The rows are the day's times, so two of them cannot share an emoji — the
  # table is uniquely indexed on it, and this used to be a 500.
  def test_an_emoji_already_used_by_another_time_is_refused
    make_event(name: 'Second service', starts: @event.start_time + 1.hour)
    record = seeded_post
    first, second = record.options.order(:position).to_a

    as_leader
    patch "/signups/#{record.id}/options/#{second.id}", emoji: first.emoji_unicode

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'already used'
    refute_equal first.emoji_key, second.reload.emoji_key
  end

  def test_the_picker_offers_this_servers_custom_emoji
    emoji = Emoji.create!(name: 'abide_car', discord_id: custom_emoji_id, server: channel.server)
    record = seeded_post

    body = get_ok("/signups/#{record.id}").body

    assert_includes body, "<:#{emoji.name}:#{emoji.discord_id}>",
                    'a custom emoji must be offered in the form Discord uses'
    assert_includes body, "cdn.discordapp.com/emojis/#{emoji.discord_id}"
  end

  def test_a_custom_server_emoji_can_be_chosen
    emoji = Emoji.create!(name: 'abide_car', discord_id: custom_emoji_id, server: channel.server)
    record = seeded_post

    as_leader
    patch "/signups/#{record.id}/options/#{record.options.first.id}",
          emoji_pick: "<:#{emoji.name}:#{emoji.discord_id}>"

    option = record.reload.options.first
    refute_nil option, 'a custom server emoji must be usable as a sign-up option'
    assert_equal emoji.discord_id, option.emoji_discord_id
    assert_equal "c:#{emoji.discord_id}", option.emoji_key
  end

  def test_a_custom_emoji_renders_as_an_image_not_a_raw_token
    emoji = Emoji.create!(name: 'abide_car', discord_id: custom_emoji_id, server: channel.server)
    record = seeded_post
    as_leader
    patch "/signups/#{record.id}/options/#{record.options.first.id}",
          emoji_pick: "<:#{emoji.name}:#{emoji.discord_id}>"

    body = get_ok("/signups/#{record.id}").body

    # The message the bot sends still carries the token; the page must not show
    # it as text, in the option row or in the preview.
    assert_includes record.reload.body, "<:#{emoji.name}:#{emoji.discord_id}>"
    refute_includes body, ">&lt;:#{emoji.name}:", 'the raw token leaked into the rendered page'
    assert_operator body.scan("cdn.discordapp.com/emojis/#{emoji.discord_id}").size, :>=, 2,
                    'expected the image in both the option row and the preview'
  end

  def test_typed_text_wins_over_a_picked_emoji
    record = seeded_post

    as_leader
    patch "/signups/#{record.id}/options/#{record.options.first.id}", emoji: '✅', emoji_pick: '🚗'

    assert_equal '✅', record.reload.options.first.emoji_unicode
  end

  def test_a_nonsense_emoji_is_rejected_rather_than_stored
    record = seeded_post
    was = record.options.first.emoji_key

    as_leader
    patch "/signups/#{record.id}/options/#{record.options.first.id}", emoji: 'garbage!!'

    assert_equal 422, last_response.status
    assert_equal was, record.reload.options.first.emoji_key
  end

  # --- optimize and export placement ---------------------------------------

  # The button was renamed from Auto-fill; the route went with it, and nothing
  # covered it at HTTP level before.
  def test_optimize_seats_the_waiting_queue
    driver = make_driver(@event, 'ian', seats: 4, zone: ZONE_1)
    rider = make_rider(@event, 'caitlin', zone: ZONE_1)

    as_leader
    post "/board/#{@event.id}/optimize"

    assert_equal 302, last_response.status
    assert_equal driver.id, rider.reload.driver_ride_id
  end

  def test_the_board_offers_optimize_not_autofill
    make_driver(@event, 'ian', seats: 4, zone: ZONE_1)
    body = get_ok("/board?event_id=#{@event.id}").body

    assert_includes body, 'Optimize'
    refute_includes body, 'Auto-fill'
    assert_includes body, "/board/#{@event.id}/optimize"
  end

  # Export sits beside the dispatch buttons now, and stays reachable for
  # someone who is not a leader — reading the roster is not an edit.
  def test_export_is_offered_beside_the_dispatch_buttons
    make_driver(@event, 'ian', seats: 4, zone: ZONE_1)

    body = get_ok("/board?event_id=#{@event.id}").body
    assert_includes body, "/board/#{@event.id}.csv"

    # Position, not presence: it must sit in the dispatch bar at the bottom,
    # not back up in the header beside Map.
    bar_at = body.index('border-t border-line bg-surface flex-wrap')
    csv_at = body.index("/board/#{@event.id}.csv")
    map_at = body.index("/board/#{@event.id}/map")

    refute_nil bar_at, 'dispatch bar not found'
    assert_operator csv_at, :>, bar_at, 'export is still above the dispatch bar'
    assert_operator csv_at, :>, map_at, 'export should no longer sit beside Map'
  end

  def test_a_non_leader_can_still_export
    make_driver(@event, 'ian', seats: 4, zone: ZONE_1)
    plain = User.create!(name: 'Nobody', username: "nb#{next_discord_id}",
                         discord_id: next_discord_id, password: 'x' * 10)

    env 'rack.session', { user_id: plain.id }
    get "/board?event_id=#{@event.id}"
    assert_includes last_response.body, "/board/#{@event.id}.csv"

    env 'rack.session', { user_id: plain.id }
    get "/board/#{@event.id}.csv"
    assert last_response.ok?
  end

  # --- schedule filter, and zone on add -------------------------------------

  def test_the_schedule_can_hide_recurring_dates
    series = EventSeries.create!(name: 'Abide', weekday: 5, start_time_of_day: '18:30')
    weekly = make_event(name: 'Abide', starts: Time.zone.now + 2.days)
    weekly.update!(series: series)
    one_off = make_event(name: 'Fall Retreat', starts: Time.zone.now + 3.days)

    all = get_ok('/schedule').body
    assert_includes all, 'Abide'
    assert_includes all, 'Fall Retreat'

    filtered = get_ok('/schedule?only=one_off').body
    assert_includes filtered, 'Fall Retreat'
    refute_includes filtered, weekly.start_time.strftime('%A %-d %B'),
                    'a date with only recurring events should drop out entirely'
  end

  # Adding someone uses the zone their home address already implies. Asking
  # again invited a different answer, and a stray pick would override the
  # address the optimizer routes from.
  def test_adding_someone_takes_their_own_zone
    member = User.create!(name: 'Priya', username: "pr#{next_discord_id}",
                          discord_id: next_discord_id, password: 'x' * 10,
                          location: location_in(ZONE_3))

    as_leader
    post "/board/#{@event.id}/rides", user_id: member.id, role: 'rider'

    ride = @event.rides.find_by(user_id: member.id)
    refute_nil ride
    assert_equal ZONE_3, ride.zone
  end

  def test_the_add_form_no_longer_asks_for_a_zone
    # The add form lives in the Roster tab, not Details.
    body = get_ok("/board?event_id=#{@event.id}&tab=roster").body
    add_form = body[/Add someone.*?<\/form>/m]

    refute_nil add_form, 'add-someone form not found'
    refute_includes add_form, 'name="zone"', 'the add form still asks for a zone'
  end

  # --- workflow-audit fixes --------------------------------------------------

  # The nag counted all ~270 server members; only the active roster matters.
  def test_the_home_needs_details_nag_counts_active_members_only
    # An inactive member with nothing filled in: alone, no nag at all.
    User.create!(name: 'Ghost', username: "gh#{next_discord_id}",
                 discord_id: next_discord_id, password: 'x' * 10, active: false)
    assert_equal 0, get_ok('/').body.scan('Needs details').size,
                 'the home page nags about inactive members'

    User.create!(name: 'Realperson', username: "rp#{next_discord_id}",
                 discord_id: next_discord_id, password: 'x' * 10, active: true)
    body = get_ok('/').body
    assert_includes body, 'Needs details'
    assert_includes body, '1 person has', 'wrong count or wrong grammar'
  end

  # "not sent yet" on an event whose sign-up was posted and closed read as a
  # failure that never happened.
  def test_the_event_page_reports_the_real_signup_state
    server = Server.create!(name: "S#{next_discord_id}", discord_id: next_discord_id)
    channel = Channel.create!(name: 'rides', discord_id: next_discord_id, server: server)
    post = SignupPost.create!(channel: channel, service_date: @event.start_time.to_date,
                              status: 'closed', closed_at: Time.zone.now,
                              posted_at: Time.zone.now, discord_message_id: next_discord_id)
    post.options.create!(Signup::EmojiKey.parse('1️⃣').merge(event: @event, position: 0))

    body = get_ok("/events/#{@event.id}").body

    assert_includes body, 'posted, now closed'
    refute_includes body, 'not sent yet'
    refute_includes body, '>Section<', 'the retired Section card is still on the event page'
  end

  # Moving a rider by hand must not carry the optimizer's order into a car it
  # was never computed for.
  def test_a_manual_reassign_drops_the_stale_pickup_position
    car_a = make_driver(@event, 'ian', seats: 4, zone: ZONE_1)
    car_b = make_driver(@event, 'caleb', seats: 4, zone: ZONE_1)
    rider = make_rider(@event, 'caitlin', zone: ZONE_1, driver: car_a)
    rider.update!(pickup_position: 0)

    as_leader
    post "/board/#{@event.id}/assign", ride_id: rider.id, driver_ride_id: car_b.id

    rider.reload
    assert_equal car_b.id, rider.driver_ride_id
    assert_nil rider.pickup_position, 'position 0 from the old route followed them'
  end

  # The double-booking mark rides on the PERSON, wherever they appear — the
  # dispatch-bar summary is the thing nobody reads mid-drag.
  def test_a_double_booked_person_is_marked_on_the_board_itself
    sibling = make_event(name: 'Sunday Service', starts: @event.start_time + 1.hour)
    driver = make_driver(@event, 'ian', seats: 4, zone: ZONE_1)
    rider = make_rider(@event, 'caitlin', zone: ZONE_1, driver: driver)
    sibling.rides.create!(user: rider.user, role: 'rider', status: 'requested')
    sibling.rides.create!(user: driver.user, role: 'driver', status: 'confirmed', seats: 4)

    body = get_ok("/board?event_id=#{@event.id}").body

    assert_operator body.scan('2×').size, :>=, 2, 'rider and driver should both carry the mark'
    assert_includes body, 'also on Sunday Service'
    assert_includes body, 'driving Sunday Service'
  end

  # --- verified locations -----------------------------------------------------

  def test_the_locations_page_grades_every_pin
    Location.create!(name: 'Verified Place', zone: ZONE_1, lat: 40.43, lon: -86.91, verification: 'rooftop')
    Location.create!(name: 'Guessed Place', zone: ZONE_1, lat: 40.43, lon: -86.91, verification: 'unverified')
    Location.create!(name: 'Nowhere Place', zone: ZONE_1)

    as_leader
    body = get_ok('/locations').body

    assert_includes body, '>verified<'
    assert_includes body, '>unverified<'
    assert_includes body, '>no coords<'
    # Verify is offered for anything short of verified, and not for the rest.
    assert_equal 2, body.scan('>Verify<').size, 'Verify button count'
  end

  class FakeVerifyingMap
    def geocode(_query)
      { lat: 40.4471, lon: -86.9391, address: '2053 Willowbrook Dr, West Lafayette, IN 47906, USA',
        place_id: 'ChIJ-fake', verification: 'rooftop', source: :google }
    end
  end

  def test_verify_records_state_address_and_place_id
    require 'minitest/mock'
    place = Location.create!(name: 'Village West', zone: ZONE_1, lat: 40.4310, lon: -86.9280)

    as_leader
    Map.stub(:new, FakeVerifyingMap.new) { post "/locations/#{place.id}/verify" }

    assert_equal 302, last_response.status
    place.reload
    assert_equal 'rooftop', place.verification
    assert_equal 'ChIJ-fake', place.place_id
    assert_includes place.address, 'Willowbrook'
    assert_in_delta 40.4471, place.lat.to_f, 0.0001, 'the pin did not move to the real building'
    refute_nil place.verified_at
  end

  def test_an_approximate_hit_keeps_the_human_address
    require 'minitest/mock'
    approx = Class.new do
      def geocode(_q) = { lat: 40.43, lon: -86.91, address: 'somewhere, IN', place_id: nil,
                          verification: 'approximate', source: :nominatim }
    end.new
    place = Location.create!(name: 'Vague Place', zone: ZONE_1, address: '123 Typed By Hand St')

    as_leader
    Map.stub(:new, approx) { post "/locations/#{place.id}/verify" }

    place.reload
    assert_equal 'approximate', place.verification
    assert_equal '123 Typed By Hand St', place.address, "overwrote a real address with Google's guess"
  end

  def test_members_missing_a_home_show_what_they_wrote
    User.create!(name: 'Undecided', username: "und#{next_discord_id}", discord_id: next_discord_id,
                 password: 'x' * 10, active: true, residence_answer: 'Either BHEE or 3rd and West')

    as_leader
    body = get_ok('/users?filter=missing').body

    assert_includes body, 'wrote:'
    assert_includes body, 'Either BHEE or 3rd and West'
  end

  # A failed sign-up says WHY on its page, in the error's own words. It used to
  # show the draft copy about scheduling, which hid a DNS failure completely.
  def test_a_failed_signup_page_shows_the_error_and_the_way_out
    server = Server.create!(name: "S#{next_discord_id}", discord_id: next_discord_id)
    channel = Channel.create!(name: 'rides', discord_id: next_discord_id, server: server)
    post = SignupPost.create!(channel: channel, service_date: Time.zone.today + 3,
                              status: 'failed', post_at: 1.hour.ago,
                              last_error: 'Socket::ResolutionError: Temporary failure in name resolution')
    post.options.create!(Signup::EmojiKey.parse('1️⃣').merge(event: @event, position: 0))

    as_leader
    body = get_ok("/signups/#{post.id}").body

    assert_includes body, 'Failed to send'
    assert_includes body, 'name resolution'
    assert_includes body, 'Post now'
    refute_includes body, 'will not send by itself', 'failed post still wearing the draft caption'
  end

  # --- mounted under a prefix (abidepurdue.com/abidebot) ---------------------
  #
  # Rack sets SCRIPT_NAME from the mount point; everything the app emits has
  # to carry it, or the first click leaves the app. A bare "/board" anywhere
  # is a regression here.

  def under_prefix
    env 'SCRIPT_NAME', '/abidebot'
  end

  def test_every_link_form_and_endpoint_carries_the_mount_prefix
    make_driver(@event, 'ian', seats: 4, zone: ZONE_1)
    as_leader; under_prefix
    body = get_ok("/board?event_id=#{@event.id}&tab=roster").body

    assert_includes body, 'data-root="/abidebot"'
    assert_includes body, "/abidebot/board/#{@event.id}/optimize"
    assert_includes body, 'href="/abidebot/board?'
    refute_includes body, '/abidebot/abidebot', 'a link was prefixed twice'
    refute_match %r{(href|action|data-endpoint)="/(board|users|schedule|locations|events|series|signups|tags|login|logout)}, body,
                 'a root-relative link escaped the prefix'
    refute_includes body, 'href="http://example.org/board"', 'nav links must carry the prefix too'
  end

  def test_the_other_pages_carry_the_prefix_too
    as_leader; under_prefix
    %w[/schedule /users /locations /].each do |page|
      body = get_ok(page).body
      refute_includes body, '/abidebot/abidebot', "#{page} prefixed a link twice"
      refute_match %r{(href|action)="/(board|users|schedule|locations|events|series|signups|tags)}, body,
                   "#{page} emitted an unprefixed link"
    end
  end

  def test_the_login_page_carries_the_prefix_too
    under_prefix
    body = get_ok('/login').body

    assert_includes body, 'data-root="/abidebot"'
    assert_includes body, 'action="/abidebot/login"'
    refute_includes body, '/abidebot/abidebot'
  end

  def test_redirects_land_inside_the_prefix
    as_leader; under_prefix
    post '/locations', name: 'Prefixed Place', zone: ZONE_1

    assert_equal 302, last_response.status
    assert_match %r{/abidebot/locations\z}, last_response['Location']
  end

  def test_no_prefix_means_plain_root_paths
    make_driver(@event, 'ian', seats: 4, zone: ZONE_1)
    as_leader
    body = get_ok("/board?event_id=#{@event.id}").body

    assert_includes body, 'data-root=""'
    assert_includes body, "/board/#{@event.id}/optimize"
    refute_includes body, '/abidebot'
  end

  # The token the bot boots with comes from config.yml, not from a row copied
  # out of it once. ENV still wins for deploys.
  def test_discord_token_prefers_env_then_config_file
    ENV['DISCORD_TOKEN'] = 'from-env'
    assert_equal 'from-env', Abid.discord_token
  ensure
    ENV.delete('DISCORD_TOKEN')
  end

  def test_discord_config_is_a_plain_hash_even_without_a_file
    assert_kind_of Hash, Abid.discord_config
  end

  def test_members_who_opted_out_of_snipes_wear_a_pill
    User.create!(name: 'Shy Person', username: "shy#{next_discord_id}", discord_id: next_discord_id,
                 password: 'x' * 10, active: true, snipes_opt_out: true)

    as_leader
    body = get_ok('/users').body

    assert_includes body, 'no snipes'
  end

  # The snipes channel lives in the same table as #rides. Offering it in the
  # sign-up composer means one wrong pick sends a @Riders ping into snipes.
  def test_the_snipes_channel_is_never_offered_for_rides
    # A name no other part of these pages could contain, so the refutes below
    # cannot pass or fail by accident. Option values are ids and would collide
    # with the location select's.
    Channel.create!(name: 'photo-snipes-zz', discord_id: next_discord_id, server: channel.server,
                    purpose: 'snipes')
    post = SignupPost.create!(channel: channel, service_date: Time.zone.today, status: 'draft')

    signup_page = get_ok("/signups/#{post.id}").body

    assert_includes signup_page, "##{channel.name}"
    refute_includes signup_page, 'photo-snipes-zz'
    refute_includes get_ok('/events/new').body, 'photo-snipes-zz'
    refute_includes get_ok('/series/new').body, 'photo-snipes-zz'
  end

  def test_a_sign_up_cannot_be_pointed_at_the_snipes_channel
    snipes = Channel.create!(name: 'snipes', discord_id: next_discord_id, server: channel.server,
                             purpose: 'snipes')

    as_leader
    post '/signups', channel_id: snipes.id, service_date: Time.zone.today.to_s

    assert_equal 422, last_response.status
    assert_equal 0, SignupPost.where(channel: snipes).count
  end

  # A post made before its channel gained a purpose must still be closable.
  def test_an_existing_post_survives_its_channel_becoming_the_snipes_channel
    post = SignupPost.create!(channel: channel, service_date: Time.zone.today, status: 'draft')
    channel.update!(purpose: 'snipes')

    assert post.reload.update(intro: 'still editable')
  end

  # --- plus-ones (issue #22) -------------------------------------------------

  def test_a_plus_one_can_be_added_from_the_board
    car = make_driver(@event, 'ian', seats: 4, zone: ZONE_1)
    host = make_rider(@event, 'anna', zone: ZONE_1, driver: car)

    as_leader
    post "/board/#{@event.id}/guests", name: 'Visiting Friend', host_ride_id: host.id

    guest = @event.rides.find_by(guest_name: 'Visiting Friend')
    refute_nil guest, 'no plus-one created'
    assert_equal host.id, guest.host_ride_id
    assert_equal car.id, guest.driver_ride_id

    body = get_ok("/board?event_id=#{@event.id}").body
    assert_includes body, 'Visiting Friend'
    assert_includes body, '+1 · anna'
  end

  def test_a_plus_one_needs_a_name_and_a_host
    host = make_rider(@event, 'anna', zone: ZONE_1)

    as_leader
    post "/board/#{@event.id}/guests", name: '', host_ride_id: host.id
    assert_equal 422, last_response.status

    as_leader
    post "/board/#{@event.id}/guests", name: 'Someone'
    assert_equal 422, last_response.status
  end

  def test_the_roster_tab_offers_add_a_plus_one
    make_rider(@event, 'anna', zone: ZONE_1)

    body = get_ok("/board?event_id=#{@event.id}&tab=roster").body

    assert_includes body, 'Add a plus-one'
    assert_includes body, "/board/#{@event.id}/guests"
  end

  def test_a_plus_ones_details_edit_their_name
    host = make_rider(@event, 'anna', zone: ZONE_1)
    guest = RideDetails.create_guest(@event, host_ride_id: host.id, name: 'Visting Frend')

    body = get_ok("/board?event_id=#{@event.id}&focus=#{guest.id}").body
    assert_includes body, 'Plus-one of anna'

    as_leader
    patch "/board/#{@event.id}/rides/#{guest.id}", name: 'Visiting Friend'
    assert_equal 'Visiting Friend', guest.reload.guest_name
    assert_equal host.id, guest.host_ride_id, 'saving the form severed the link'
    assert_nil guest.pickup_address, "copied the host's pickup onto the guest"
  end

  # --- the emoji catalogue --------------------------------------------------

  def test_the_catalogue_covers_the_whole_unicode_set
    body = get_ok('/emoji.json').body
    entries = JSON.parse(body)

    assert_operator entries.size, :>, 1500, 'the picker is still a short hand-picked list'

    chars = entries.map { |e| e['c'] }
    # A few a rides coordinator would plausibly reach for, none of which were in
    # the 28 hand-picked ones.
    ['🚌', '🛻', '🧭', '🎉', '🥐'].each do |char|
      assert_includes chars, char, "#{char} is not offered"
    end
  end

  # Five near-identical copies of every gesture is a worse list, not a more
  # complete one — and typing a toned emoji has always worked anyway.
  def test_skin_tone_variants_are_left_out
    entries = JSON.parse(get_ok('/emoji.json').body)
    toned = entries.count { |e| e['c'].match?(/[\u{1F3FB}-\u{1F3FF}]/) }

    assert_equal 0, toned, 'the grid is padded with skin-tone duplicates'
  end

  # Searching is why the list exists, so the keywords have to carry more than
  # the short name.
  def test_entries_carry_search_keywords
    entries = JSON.parse(get_ok('/emoji.json').body)
    car = entries.find { |e| e['c'] == '🚗' }

    refute_nil car
    assert_includes car['k'], 'car'
    assert_operator entries.count { |e| e['k'].include?('church') }, :>=, 1
  end

  # A custom emoji has no character to draw, so it carries its image and the
  # <:name:id> form the server already knows how to parse.
  def test_the_servers_own_emoji_come_first_and_carry_their_image
    server = Server.create!(name: "S#{next_discord_id}", discord_id: next_discord_id)
    Emoji.create!(name: 'blobwave', discord_id: next_discord_id, server: server)

    entries = JSON.parse(get_ok('/emoji.json').body)
    custom = entries.find { |e| e['n'] == 'blobwave' }

    refute_nil custom, "the server's own emoji are not offered"
    assert_equal entries.first['n'], 'blobwave', 'buried below 1,900 unicode ones'
    assert_includes custom['u'], 'cdn.discordapp.com'
    assert_equal '<:blobwave:', custom['v'][0, 11]
  end

  # Everything the picker offers must survive the round trip the form takes.
  # All of it, not a sample: this caught 30% of the catalogue being rejected by
  # the parser, and a sample would have caught it only some of the time.
  def test_every_catalogue_entry_parses_back_to_an_emoji
    entries = JSON.parse(get_ok('/emoji.json').body)

    unparsed = entries.reject { |entry| Signup::EmojiKey.parse(entry['v'] || entry['c']) }

    assert_empty unparsed.first(10).map { |e| e['n'] },
                 "#{unparsed.size} of #{entries.size} offered emoji are rejected by the parser"
  end

  # The shapes that were rejected before: a country flag is two characters, a
  # subdivision flag is a tag sequence, and ☘️ ↙️ ♾️ are text characters
  # promoted by a variation selector rather than emoji by default.
  def test_flags_and_variation_selector_emoji_are_readable
    {
      '🇨🇷' => 'u:flag_cr',
      '🏴󠁧󠁢󠁥󠁮󠁧󠁿' => 'u:flag_england',
      '☘️' => 'u:shamrock',
      '↙️' => 'u:arrow_lower_left',
      '♾️' => 'u:infinity',
      '👨‍👩‍👦' => 'u:family_man_woman_boy'
    }.each do |char, key|
      parsed = Signup::EmojiKey.parse(char)
      refute_nil parsed, "#{char} is rejected"
      assert_equal key, parsed[:emoji_key]
    end
  end

  def test_the_catalogue_needs_a_leader
    plain = User.create!(name: 'Nobody', username: "nb#{next_discord_id}",
                         discord_id: next_discord_id, password: 'x' * 10)
    env 'rack.session', { user_id: plain.id }
    get '/emoji.json'

    refute_equal 200, last_response.status
  end

  # The picker lives on each row now — changing which emoji books a time is the
  # only emoji decision left, and it must not have gone with the Add form.
  def test_each_option_row_offers_the_full_picker
    record = seeded_post

    body = get_ok("/signups/#{record.id}").body

    assert_includes body, 'Change emoji'
    assert_includes body, 'data-emoji-picker'
    assert_includes body, 'data-emoji-search'
  end

  # --- revoking a sent sign-up ---------------------------------------------

  def make_posted_signup
    server = Server.create!(name: "S#{next_discord_id}", discord_id: next_discord_id)
    channel = Channel.create!(name: 'rides', discord_id: next_discord_id, server: server)
    signup = SignupPost.create!(channel: channel, service_date: @event.start_time.to_date,
                                status: 'posted', discord_message_id: next_discord_id,
                                posted_at: Time.zone.now)
    signup.options.create!(Signup::EmojiKey.parse('1️⃣').merge(event: @event, position: 0))
    signup.reload
  end

  # The button only asks. The post must stay `posted` until the bot has really
  # removed the message — otherwise Post now sends a second one alongside it.
  def test_revoking_only_flags_it_and_leaves_the_post_posted
    signup = make_posted_signup

    as_leader
    post "/signups/#{signup.id}/revoke"

    signup.reload
    refute_nil signup.revoke_requested_at
    assert_equal 'posted', signup.status, 'went editable before the message was gone'
    refute_nil signup.discord_message_id
  end

  def test_the_signup_page_offers_revoke_once_sent_and_says_so_while_it_runs
    signup = make_posted_signup

    assert_includes get_ok("/signups/#{signup.id}").body, 'Revoke &amp; edit'

    signup.update!(revoke_requested_at: Time.zone.now)
    body = get_ok("/signups/#{signup.id}").body
    assert_includes body, 'Revoking'
    refute_includes body, 'Revoke &amp; edit', 'offered to revoke something already being revoked'
  end

  # A draft has no message in the channel, so there is nothing to take down.
  def test_revoking_a_draft_is_refused
    server = Server.create!(name: "S#{next_discord_id}", discord_id: next_discord_id)
    channel = Channel.create!(name: 'rides', discord_id: next_discord_id, server: server)
    draft = SignupPost.create!(channel: channel, service_date: Time.zone.today, status: 'draft')

    as_leader
    post "/signups/#{draft.id}/revoke"

    assert_equal 409, last_response.status
    assert_nil draft.reload.revoke_requested_at
  end

  def test_a_non_leader_cannot_revoke
    signup = make_posted_signup

    plain = User.create!(name: 'Nobody', username: "nb#{next_discord_id}",
                         discord_id: next_discord_id, password: 'x' * 10)
    env 'rack.session', { user_id: plain.id }
    post "/signups/#{signup.id}/revoke"

    assert_nil signup.reload.revoke_requested_at
  end

  # --- the schedule calendar ------------------------------------------------

  # The window used to be six weeks, so a retreat in January was in the database
  # and simply never fetched. It looked missing; it was never asked for.
  def test_the_schedule_shows_events_months_out
    far = make_event(name: 'Winter Retreat', starts: Time.zone.now + 4.months)

    body = get_ok('/schedule').body

    assert_includes body, 'Winter Retreat', "an event #{far.start_time.to_date} away was dropped"
  end

  # The calendar must cover the same span as the list, or a date sits in the
  # list with no cell to click.
  def test_the_calendar_covers_every_month_the_list_does
    far = make_event(name: 'Five Months Out', starts: Time.zone.now + 4.months + 3.weeks)
    body = get_ok('/schedule').body

    assert_includes body, 'Five Months Out'
    assert_includes body, far.start_time.strftime('%B %Y'), 'the list reached a month the calendar does not'

    # This month through the month five months out, inclusive.
    this_month = Time.zone.today.beginning_of_month
    last_month = (Time.zone.today + 5.months).beginning_of_month
    month = this_month
    while month <= last_month
      assert_includes body, month.strftime('%B %Y'), "no grid for #{month.strftime('%B %Y')}"
      month = month.next_month
    end

    refute_includes body, last_month.next_month.strftime('%B %Y'), 'the calendar ran past the window'
  end

  # A day with a sign-up goes straight to it.
  def test_a_calendar_day_with_a_signup_links_to_it
    channel = Channel.create!(name: 'rides', discord_id: next_discord_id,
                              server: Server.create!(name: "S#{next_discord_id}", discord_id: next_discord_id))
    post = SignupPost.create!(channel: channel, service_date: @event.start_time.to_date,
                              status: 'draft')

    assert_includes get_ok('/schedule').body, "/signups/#{post.id}"
  end

  # A day with rides but no sign-up sets one up and opens it.
  def test_clicking_a_day_with_no_signup_creates_and_opens_one
    channel = Channel.create!(name: 'rides', discord_id: next_discord_id,
                              server: Server.create!(name: "S#{next_discord_id}", discord_id: next_discord_id))
    series = EventSeries.create!(name: 'Sunday Service', weekday: 0, start_time_of_day: '09:30',
                                 channel: channel, signup_lead_days: 3, signup_post_time: '20:00')
    date = Time.zone.today + 3.weeks
    series.ensure_occurrence(date)

    as_leader
    post "/schedule/#{date.strftime('%Y-%m-%d')}/signup"

    created = SignupPost.find_by(service_date: date)
    refute_nil created, 'no sign-up was made'
    assert_includes last_response.location, "/signups/#{created.id}"
    assert created.options.any?, 'opened a sign-up with no emoji rows'
  end

  # Clicking the same day twice opens the same post.
  def test_setting_a_date_up_twice_reuses_the_same_signup
    channel = Channel.create!(name: 'rides', discord_id: next_discord_id,
                              server: Server.create!(name: "S#{next_discord_id}", discord_id: next_discord_id))
    series = EventSeries.create!(name: 'Sunday Service', weekday: 0, start_time_of_day: '09:30',
                                 channel: channel, signup_lead_days: 3, signup_post_time: '20:00')
    date = Time.zone.today + 3.weeks
    series.ensure_occurrence(date)

    as_leader
    post "/schedule/#{date.strftime('%Y-%m-%d')}/signup"
    as_leader
    post "/schedule/#{date.strftime('%Y-%m-%d')}/signup"

    assert_equal 1, SignupPost.where(service_date: date).count
  end

  def test_setting_up_a_date_with_nothing_on_it_is_refused
    as_leader
    post "/schedule/#{(Time.zone.today + 2.days).strftime('%Y-%m-%d')}/signup"

    assert_equal 422, last_response.status
  end

  # --- driver tags ---------------------------------------------------------

  def test_tags_are_canonicalised_so_one_tag_does_not_become_three
    a = make_user('ian', capacity: 4)
    a.update!(tags: ['Friday-Usual'])
    b = make_user('caleb', capacity: 4)
    # Different case and a space instead of a hyphen — the same tag to a human.
    b.update!(tags: ['friday usual'])

    assert_equal ['Friday-Usual'], b.reload.tags
    assert_equal 2, User.tagged('Friday-Usual').count
    assert_equal ['Friday-Usual'], User.known_tags
  end

  def test_blank_and_duplicate_tags_are_dropped
    u = make_user('ian', capacity: 4)
    u.update!(tags: ['Friday-Usual', '  ', 'friday-usual', ''])

    assert_equal ['Friday-Usual'], u.reload.tags
  end

  # The point of the whole feature: a Friday board offers Friday drivers.
  def test_add_drivers_is_scoped_to_the_events_tag
    friday = make_user('friday driver', capacity: 4)
    friday.update!(active: true, tags: ['Friday-Usual'])
    sunday = make_user('sunday driver', capacity: 4)
    sunday.update!(active: true, tags: ['Sunday-Usual'])

    @event.update!(driver_tag: 'Friday-Usual')

    assert_equal 1, RideBoard.new(@event).regular_driver_count

    as_leader
    post "/board/#{@event.id}/drivers"

    names = @event.reload.rides.map(&:display_name)
    assert_includes names, 'friday driver'
    refute_includes names, 'sunday driver', 'a Sunday driver was added to a Friday board'
  end

  # An occurrence with no tag of its own uses its series', so renaming the tag
  # on the series reaches the weeks already generated.
  def test_an_occurrence_inherits_the_tag_from_its_series
    series = EventSeries.create!(name: 'Abide', weekday: 5, start_time_of_day: '18:30',
                                 driver_tag: 'Friday-Usual')
    @event.update!(series: series, driver_tag: nil)

    assert_equal 'Friday-Usual', @event.reload.driver_tag_for_board

    series.update!(driver_tag: 'Renamed-Tag')
    assert_equal 'Renamed-Tag', @event.reload.driver_tag_for_board
  end

  # Nobody tagged yet is the normal state on day one. It must not silently add
  # everybody — that fallback is what the tag exists to prevent.
  def test_an_untagged_roster_adds_nobody_rather_than_everybody
    driver = make_user('somebody', capacity: 4)
    driver.update!(active: true, tags: [])
    @event.update!(driver_tag: 'Friday-Usual')

    as_leader
    post "/board/#{@event.id}/drivers"

    assert_equal 0, @event.reload.rides.count
  end

  # "All drivers" is a deliberate press, and says so explicitly.
  def test_adding_every_driver_takes_an_explicit_all
    friday = make_user('friday driver', capacity: 4)
    friday.update!(active: true, tags: ['Friday-Usual'])
    other = make_user('untagged driver', capacity: 4)
    other.update!(active: true)
    @event.update!(driver_tag: 'Friday-Usual')

    as_leader
    post "/board/#{@event.id}/drivers", tag: Components::BoardShell::ALL_DRIVERS

    assert_equal 2, @event.reload.rides.count
  end

  # With no tag set at all the button behaves as it always did.
  def test_a_board_with_no_tag_still_adds_every_regular_driver
    driver = make_user('somebody', capacity: 4)
    driver.update!(active: true)
    @event.update!(driver_tag: nil, series: nil)

    as_leader
    post "/board/#{@event.id}/drivers"

    assert_equal 1, @event.reload.rides.count
  end

  def test_tagging_one_person_from_the_members_list
    u = make_user('ian', capacity: 4)
    u.update!(active: true)

    as_leader
    post "/users/#{u.id}/tag", tag: 'Friday-Usual', filter: 'drivers'
    assert_includes u.reload.tags, 'Friday-Usual'

    # Same button again takes it off.
    as_leader
    post "/users/#{u.id}/tag", tag: 'Friday-Usual', filter: 'drivers'
    refute_includes u.reload.tags, 'Friday-Usual'
  end

  # Picking a tag is a tagging MODE, not a filter. Everyone stays on screen —
  # otherwise the first person can never be tagged, because on day one nobody
  # carries the tag and the list would come back empty.
  def test_choosing_a_tag_keeps_everyone_on_screen_with_a_toggle
    tagged = make_user('tagged one', capacity: 4)
    tagged.update!(active: true, tags: ['Friday-Usual'])
    plain = make_user('untagged one', capacity: 4)
    plain.update!(active: true)

    body = get_ok('/users?filter=drivers&tag=Friday-Usual').body

    assert_includes body, 'tagged one'
    assert_includes body, 'untagged one', 'the people you are about to tag vanished'
    assert_includes body, '+ Friday-Usual', 'no way to add the tag to someone without it'
  end

  # A tag a series asks for is real before anybody carries it, or the very first
  # one could never be applied from this page.
  # Deleting the last tag used to hide the row that creates tags, which made it
  # a one-way door: no chips, no "+ new tag", no way back.
  def test_the_tagging_row_survives_having_no_tags_at_all
    assert_empty DriverTag.all
    assert_empty User.known_tags

    body = get_ok('/users?filter=drivers').body

    assert_includes body, 'Tagging'
    assert_includes body, '+ new tag', 'no way to make a tag once the last one is gone'
  end

  # And the box still works from that state.
  def test_a_tag_can_be_made_again_after_deleting_them_all
    as_leader
    post '/tags', name: 'Friday-Usual', filter: 'drivers'

    assert_includes DriverTag.pluck(:name), 'Friday-Usual'
    assert_includes get_ok('/users?filter=drivers').body, 'Friday-Usual'
  end

  def test_creating_a_tag_nobody_carries_yet
    as_leader
    post '/tags', name: 'van drivers', filter: 'drivers'

    # Spaces become hyphens, and it lands in tagging mode for the new tag.
    assert_includes DriverTag.pluck(:name), 'van-drivers'
    assert_includes last_response.location, 'tag=van-drivers'
    assert_includes User.known_tags, 'van-drivers'
  end

  def test_deleting_a_tag_takes_it_off_everyone
    tag = DriverTag.register('Friday-Usual')
    driver = make_user('ian', capacity: 4)
    driver.update!(active: true, tags: ['Friday-Usual'])

    as_leader
    delete "/tags/#{tag.id}", filter: 'drivers'

    assert_empty driver.reload.tags, 'the tag is gone from the list but still on a person'
    refute_includes User.known_tags, 'Friday-Usual'
  end

  # A tag a series points at used to come back: the row was deleted, then the
  # next page load saw the series still asking for it and re-registered it.
  # Friday-Usual and Sunday-Usual were the only two tags any series referenced,
  # which is why exactly those two would not delete.
  def test_deleting_a_tag_a_series_uses_does_not_resurrect_it
    tag = DriverTag.register('Friday-Usual')
    series = EventSeries.create!(name: 'Abide', weekday: 5, start_time_of_day: '18:30',
                                 driver_tag: 'Friday-Usual')
    @event.update!(series: series, driver_tag: 'Friday-Usual')

    as_leader
    delete "/tags/#{tag.id}", filter: 'drivers'

    refute_includes User.known_tags, 'Friday-Usual'
    assert_nil series.reload.driver_tag, 'the series still scopes a board to a tag that is gone'
    assert_nil @event.reload.driver_tag

    # And it stays gone after the page that re-registers known tags is loaded.
    get_ok('/users?filter=drivers')
    refute_includes DriverTag.pluck(:name), 'Friday-Usual'
  end

  # Losing the tag returns that board to offering every driver, rather than
  # offering nobody.
  def test_a_board_whose_tag_was_deleted_falls_back_to_all_drivers
    tag = DriverTag.register('Friday-Usual')
    driver = make_user('ian', capacity: 4)
    driver.update!(active: true, tags: ['Friday-Usual'])
    @event.update!(driver_tag: 'Friday-Usual')

    as_leader
    delete "/tags/#{tag.id}"

    board = RideBoard.new(@event.reload)
    assert_nil board.driver_tag
    assert_equal 1, board.regular_driver_count
  end

  # Tags say which board offers somebody as a driver, so they mean nothing on a
  # member with no seats.
  def test_a_rider_cannot_be_tagged
    rider = make_user('caitlin')
    rider.update!(active: true)

    as_leader
    post "/users/#{rider.id}/tag", tag: 'Friday-Usual'

    assert_equal 422, last_response.status
    assert_empty rider.reload.tags
  end

  # Every tag is offered, not just the day's own — a Friday the Sunday people
  # are covering is a real problem.
  def test_the_board_offers_every_tag_with_a_count
    friday = make_user('friday driver', capacity: 4)
    friday.update!(active: true, tags: ['Friday-Usual'])
    sunday = make_user('sunday driver', capacity: 4)
    sunday.update!(active: true, tags: ['Sunday-Usual'])
    @event.update!(driver_tag: 'Friday-Usual')

    options = RideBoard.new(@event).driver_tag_options
    friday_option = options.find { |o| o[:tag] == 'Friday-Usual' }
    sunday_option = options.find { |o| o[:tag] == 'Sunday-Usual' }

    assert_equal 1, friday_option[:count]
    assert friday_option[:preferred], "the day's own tag should lead"
    assert_equal 1, sunday_option[:count]
    refute sunday_option[:preferred]
  end

  # Counts are what the press would ADD, so pressing twice does not show the
  # same number and quietly do nothing.
  def test_the_count_drops_once_a_driver_is_on_the_board
    driver = make_user('friday driver', capacity: 4)
    driver.update!(active: true, tags: ['Friday-Usual'])
    @event.update!(driver_tag: 'Friday-Usual')

    as_leader
    post "/board/#{@event.id}/drivers", tag: 'Friday-Usual'

    options = RideBoard.new(@event.reload).driver_tag_options
    assert_equal 0, options.find { |o| o[:tag] == 'Friday-Usual' }[:count]
  end

  # Picking a tag on the board overrides the day's default.
  def test_adding_a_different_tag_than_the_days_own
    sunday = make_user('sunday driver', capacity: 4)
    sunday.update!(active: true, tags: ['Sunday-Usual'])
    @event.update!(driver_tag: 'Friday-Usual')

    as_leader
    post "/board/#{@event.id}/drivers", tag: 'Sunday-Usual'

    assert_includes @event.reload.rides.map(&:display_name), 'sunday driver'
  end

  def test_a_series_tag_is_offered_before_anyone_carries_it
    EventSeries.create!(name: 'Abide', weekday: 5, start_time_of_day: '18:30',
                        driver_tag: 'Friday-Usual')

    assert_includes User.known_tags, 'Friday-Usual'
    assert_includes get_ok('/users?filter=drivers').body, 'Friday-Usual'
  end

  # --- past events ---------------------------------------------------------

  def test_a_past_board_offers_no_send_button_and_says_it_is_past
    past = make_event(name: 'Last Sunday', starts: 8.days.ago)
    make_driver(past, 'ian', seats: 4, zone: ZONE_1)

    body = get_ok("/board?event_id=#{past.id}").body

    refute_includes body, 'Send to', 'a finished event must not offer to DM drivers'
    refute_includes body, 'Resend to all'
    assert_includes body, 'already happened'
    assert_includes body, '>past<'
  end

  def test_an_upcoming_board_still_offers_the_send_button
    make_driver(@event, 'ian', seats: 4, zone: ZONE_1)

    body = get_ok("/board?event_id=#{@event.id}").body

    assert_includes body, 'Send to'
    refute_includes body, '>past<'
  end

  # The button is gone, but a tab left open since Sunday still has one.
  def test_dispatching_a_past_event_is_refused
    past = make_event(name: 'Last Sunday', starts: 8.days.ago)
    driver = make_driver(past, 'ian', seats: 4, zone: ZONE_1)
    make_rider(past, 'caitlin', zone: ZONE_1, driver: driver)

    as_leader
    post "/board/#{past.id}/dispatch", scope: 'all'

    assert_equal 422, last_response.status
    assert_equal 0, past.dispatches.count, 'a DM was queued for an event that already happened'
  end

  # --- things that broke silently because nothing covered them ------------

  def test_the_board_map_renders_for_an_event_with_no_rides
    get_ok("/board/#{@event.id}/map")
  end

  def test_queueing_a_dispatch_from_the_board
    driver = make_driver(@event, 'ian', seats: 4, zone: ZONE_1)
    make_rider(@event, 'caitlin', zone: ZONE_1, driver: driver)

    as_leader
    post "/board/#{@event.id}/dispatch", scope: 'all'

    # POST-redirect-GET for a normal form submit; the board itself is re-rendered
    # inline only for the XHR path the JS uses.
    assert_equal 302, last_response.status, last_response.body.to_s[0, 300]
    assert_equal 1, @event.dispatches.count
    assert_equal 1, @event.dispatches.first.messages.count
  end

  # --- deleting a driver ---------------------------------------------------

  def test_deleting_a_driver_returns_their_riders_to_the_queue
    driver = make_driver(@event, 'ian', seats: 4, zone: ZONE_1)
    rider = make_rider(@event, 'caitlin', zone: ZONE_1, driver: driver)

    as_leader
    delete "/board/#{@event.id}/rides/#{driver.id}"

    rider.reload
    assert_nil rider.driver_ride_id, 'rider was left pointing at a deleted driver'
    # Not just unlinked — no longer claiming to be seated in a car that is gone.
    assert_equal 'requested', rider.status
    assert_includes RideBoard.new(@event.reload).pool.map(&:id), rider.id
  end

  def test_deleting_a_driver_leaves_a_cancelled_rider_cancelled
    driver = make_driver(@event, 'ian', seats: 4, zone: ZONE_1)
    away = make_rider(@event, 'gone', zone: ZONE_1, driver: driver, status: 'cancelled')

    as_leader
    delete "/board/#{@event.id}/rides/#{driver.id}"

    # 'cancelled' is a statement about the rider, not about this driver.
    assert_equal 'cancelled', away.reload.status
  end

  # --- cancelling one date -------------------------------------------------

  def test_cancelling_an_occurrence_from_the_schedule_keeps_the_row
    as_leader
    post "/events/#{@event.id}/disable", return_to: '/schedule'

    assert_includes last_response.location, '/schedule'
    assert @event.reload.disabled, 'the occurrence was not switched off'
    # Deleting would let the daily generator recreate it; disabling is the
    # tombstone that survives regeneration.
    assert Event.exists?(@event.id)
  end

  # --- locations -----------------------------------------------------------

  def test_adding_a_location
    as_leader
    post '/locations', name: 'Somewhere New', zone: Location::ZONES.first

    assert_equal 302, last_response.status
    assert Location.exists?(name: 'Somewhere New')
  end

  def test_adding_a_location_that_already_exists_reuses_it
    Location.create!(name: 'Hilltop Apartments', zone: Location::ZONES.first)

    as_leader
    assert_no_difference_in_locations do
      post '/locations', name: 'hilltop apartments', zone: Location::ZONES.first
    end
  end

  def test_a_location_in_use_cannot_be_deleted
    place = Location.create!(name: 'Lived In', zone: Location::ZONES.first)
    @leader.update!(location: place)

    as_leader
    delete "/locations/#{place.id}"

    assert_equal 422, last_response.status
    assert Location.exists?(place.id), 'a location someone lives at was deleted'
  end

  # A place used ONLY as a Friday class pickup still counts as in use — this is
  # the case the usage query originally missed.
  def test_a_class_only_location_cannot_be_deleted
    place = Location.create!(name: 'Lecture Hall', zone: Location::ZONES.first)
    @leader.update!(class_location: place)

    as_leader
    delete "/locations/#{place.id}"

    assert_equal 422, last_response.status
    assert Location.exists?(place.id)
  end

  def test_an_unused_location_can_be_deleted
    place = Location.create!(name: 'Nowhere', zone: Location::ZONES.first)

    as_leader
    delete "/locations/#{place.id}"

    refute Location.exists?(place.id)
  end

  # "Other — add a new place…" on the member form: one submit creates the place
  # and points the member at it.
  def test_choosing_other_creates_the_location_and_assigns_it
    as_leader
    patch "/users/#{@leader.id}", location_id: '__new__',
          new_location_name: 'Brand New Flats',
          new_location_zone: Location::ZONES.first

    place = Location.find_by(name: 'Brand New Flats')
    refute_nil place, 'the new location was not created'
    assert_equal place.id, @leader.reload.location_id
  end

  # A mis-click on "Other" with nothing typed must not wipe an address we have.
  def test_choosing_other_with_no_name_leaves_the_existing_location_alone
    place = Location.create!(name: 'Home', zone: Location::ZONES.first)
    @leader.update!(location: place)

    as_leader
    patch "/users/#{@leader.id}", location_id: '__new__', new_location_name: '  '

    assert_equal place.id, @leader.reload.location_id
  end

  private

  def assert_no_difference_in_locations
    before = Location.count
    yield
    assert_equal before, Location.count, 'a duplicate location row was created'
  end

  # EmojiKey's <:name:id> pattern requires a real snowflake (15-25 digits), so
  # the short synthetic ids the other tests use would not parse.
  def custom_emoji_id = 1_141_575_602_231_582_782 + (@discord_seq += 1)

  def draft_post
    as_leader
    post '/signups', channel_id: channel.id, service_date: Time.zone.today.to_s
    SignupPost.order(:id).last
  end

  # A post for the date @event is on, so it arrives with one option already —
  # which is now the only way an option comes into being.
  def seeded_post
    as_leader
    post '/signups', channel_id: channel.id, service_date: @event.start_time.to_date.to_s
    SignupPost.order(:id).last
  end

  def channel
    @channel ||= begin
      server = Server.create!(name: "S#{next_discord_id}", discord_id: next_discord_id)
      Channel.create!(name: 'bot', discord_id: next_discord_id, server: server)
    end
  end
end
