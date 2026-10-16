require_relative 'config/environment'

require 'digest'
require 'json'
require 'uri'
require 'sinatra/activerecord'
require 'phlex-sinatra'
require 'phlex'

# Models, services and views are loaded by config.ru through Rack::Unreloader so
# they can hot-reload in development; don't plain-require them here or the
# reloader loses track of them.

class App < Sinatra::Base
  helpers Phlex::Sinatra
  register Sinatra::ActiveRecordExtension

  # Connect using the same ENV-aware config the bot and console use, rather than
  # letting the extension read config/database.yml on its own.
  set :database, Abid.database_config

  # The board's edit/delete forms rely on _method; Sinatra::Base leaves this off
  # by default (unlike a classic Sinatra app).
  enable :method_override

  set :sessions,
      httponly: true,
      secure: production?,
      same_site: :lax,
      expire_after: 60 * 60 * 24 * 14
  set :session_secret, Abid.session_secret

  before do
    # Lets Layout highlight the active nav entry without every page view
    # threading the path through its constructor.
    Abid.current_path = request.path_info
    ensure_logged_in
  end

  get '/' do
    upcoming = Event.active.upcoming.includes(:location, :series, rides: :user).chronological.limit(6).to_a
    next_event = upcoming.first

    phlex Home.new(
      next_event: next_event,
      board: next_event && RideBoard.new(next_event),
      upcoming: upcoming.drop(1),
      # Active members only: the server holds ~190 people who joined once and
      # never came, and nagging about their missing phone numbers buried the
      # handful that actually matter.
      needs_setup: User.active.missing_details.to_a,
      leader: leader?
    )
  end

  get '/login' do
    phlex Login.new
  end

  post '/login' do
    # Case-insensitive: Discord usernames are lowercase now, but rows synced from
    # older accounts can be mixed case.
    user = User.where('lower(username) = ?', params[:username].to_s.strip.downcase).first

    # user may be nil, and authenticate returns false on a bad password, so this
    # has to be a safe-navigation check rather than `user.authenticate(...)`.
    if user&.authenticate(params[:password].to_s)
      session[:user_id] = user.id
      redirect to('/')
    else
      status 401
      phlex Login.new(error: 'Incorrect username or password.')
    end
  end

  get '/logout' do
    session.clear
    redirect to('/login')
  end

  # --- events ---------------------------------------------------------------

  # Must precede '/events/:id', which would otherwise match "new".
  get '/events/new' do
    require_leader!
    phlex EventForm.new(
      event: Event.new(start_time: prefilled_start_time, location_id: default_venue_id),
      **form_collections, leader: leader?
    )
  end

  post '/events' do
    require_leader!
    event = Event.new(event_params)
    if event.save
      redirect to("/events/#{event.id}")
    else
      status 422
      phlex EventForm.new(event: event, **form_collections, leader: leader?,
                          error: event.errors.full_messages.to_sentence)
    end
  end

  get '/events/:id.csv' do
    event = find_event(params[:id]) or halt 404, 'No such event'
    content_type 'text/csv'
    attachment "rides-#{event.start_time&.strftime('%Y-%m-%d') || event.id}.csv"
    RideBoardCsv.new(RideBoard.new(event)).to_csv
  end

  get '/events/:id' do
    event = find_event(params[:id]) or halt 404, 'No such event'
    phlex EventShow.new(event: event, board: RideBoard.new(event), leader: leader?)
  end

  get '/events/:id/edit' do
    require_leader!
    event = find_event(params[:id]) or halt 404, 'No such event'
    phlex EventForm.new(event: event, **form_collections, leader: leader?)
  end

  patch '/events/:id' do
    require_leader!
    event = find_event(params[:id]) or halt 404, 'No such event'
    if event.update(event_params)
      redirect to("/events/#{event.id}")
    else
      status 422
      phlex EventForm.new(event: event, **form_collections, leader: leader?,
                          error: event.errors.full_messages.to_sentence)
    end
  end

  # Disable, never destroy — a past occurrence is the only record of who rode
  # with whom.
  post '/events/:id/disable' do
    require_leader!
    event = find_event(params[:id]) or halt 404, 'No such event'
    event.update(disabled: !event.disabled)
    # Cancelling from the schedule should land back on the schedule. Only a
    # known-safe internal path, never an arbitrary redirect target.
    redirect to(params[:return_to] == '/schedule' ? '/schedule' : "/events/#{event.id}")
  end

  # --- members --------------------------------------------------------------

  get '/users' do
    filter = %w[active other drivers riders missing].include?(params[:filter]) ? params[:filter] : 'active'
    # Anything a person or a series already refers to becomes manageable here,
    # so a tag from before the registry existed is not stuck being uneditable.
    User.known_tags.each { |t| DriverTag.register(t) }

    # Not a filter: picking a tag turns each row into a toggle for it, so the
    # people you are about to tag are still on screen. Filtering to a tag nobody
    # has yet would show an empty list and no way out of it.
    tag = User.known_tags.find { |t| t.casecmp?(params[:tag].to_s) }
    users = users_for(filter, params[:q])

    phlex UsersIndex.new(
      users: users,
      load: DriverLoad.new,
      filter: filter,
      query: params[:q],
      counts: user_counts,
      tags: DriverTag.by_name.to_a,
      tag: tag,
      leader: leader?
    )
  end

  get '/users/:id' do
    user = User.find_by(id: params[:id]) or halt 404, 'No such member'
    phlex user_page(user)
  end

  # One click from the members list. Returns to the tab and search you were on,
  # so marking a dozen people active in a row does not bounce you back to the
  # top of an unfiltered list each time.
  post '/users/:id/active' do
    require_leader!
    user = User.find_by(id: params[:id]) or halt 404, 'No such member'
    user.update(active: params[:active] != '0')

    back = URI.encode_www_form(
      { filter: params[:filter].presence, q: params[:q].presence }.compact
    )
    redirect to(back.empty? ? '/users' : "/users?#{back}")
  end

  # Make a tag that nobody carries yet, then drop straight into tagging mode for
  # it — creating a tag and having nothing to do with it is never the intent.
  post '/tags' do
    require_leader!
    tag = DriverTag.register(params[:name]) or halt 422, 'A tag needs a name'

    back = { filter: params[:filter].presence || 'drivers', tag: tag.name }.compact
    redirect to("/users?#{URI.encode_www_form(back)}")
  end

  # Retiring a tag takes it off everyone carrying it, so it cannot linger as an
  # invisible scope on a board.
  delete '/tags/:id' do
    require_leader!
    tag = DriverTag.find_by(id: params[:id]) or halt 404, 'No such tag'
    tag.retire!

    redirect to("/users?filter=#{params[:filter].presence || 'drivers'}")
  end

  # Toggle one tag from the members list. Tagging six Friday drivers should be
  # six clicks in one place, not six visits to six member pages.
  post '/users/:id/tag' do
    require_leader!
    user = User.find_by(id: params[:id]) or halt 404, 'No such member'
    tag = User.canonical_tag(params[:tag]) or halt 422, 'No tag given'
    # Tags say which board offers somebody as a driver, so they mean nothing on
    # a member with no seats. The button is not rendered for them either.
    halt 422, "#{user.display_name} has no car seats" unless user.can_drive?

    user.tags = user.tagged?(tag) ? user.tags.reject { |t| t.casecmp?(tag) } : user.tags + [tag]
    user.save!

    back = URI.encode_www_form(
      { filter: params[:filter].presence, q: params[:q].presence, tag: params[:tag].presence }.compact
    )
    redirect to(back.empty? ? '/users' : "/users?#{back}")
  end

  patch '/users/:id' do
    require_leader!
    user = User.find_by(id: params[:id]) or halt 404, 'No such member'

    if user.update(user_params)
      redirect to("/users/#{user.id}")
    else
      status 422
      phlex user_page(user, error: user.errors.full_messages.to_sentence)
    end
  end

  # --- locations ------------------------------------------------------------

  # Read-only. The list is real geography maintained in db/locations.rb, not
  # per-event data, so there is deliberately no editing UI.
  get '/locations' do
    locations = Location.order(:name).to_a
    phlex LocationsIndex.new(
      by_zone: locations.select(&:zone).group_by(&:zone),
      unzoned: locations.reject(&:zone),
      usage: location_usage,
      leader: leader?
    )
  end

  # Add a place that is not in db/locations.rb — a new complex, a building
  # nobody had needed yet. Geocoded on save like the address form, so it is
  # usable on the map immediately.
  post '/locations' do
    require_leader!
    find_or_create_location(
      name: params[:name], zone: params[:zone], address: params[:address]
    ) or halt 422, 'A location needs a name'

    redirect to('/locations')
  end

  # Only ever a place nothing points at. The usage counts on the page are the
  # same ones checked here, so the button is not offered for anything in use —
  # but the check is repeated server-side because a stale page is one click away
  # from orphaning somebody's home address.
  delete '/locations/:id' do
    require_leader!
    location = Location.find_by(id: params[:id]) or halt 404, 'No such location'

    counts = location_usage[location.id] || {}
    if counts.values.sum.positive?
      halt 422, "#{location.name} is still in use — #{describe_usage(counts)}"
    end

    location.destroy
    redirect to('/locations')
  end

  # The address is the one piece of a location a human has to supply: OSM knows
  # streets, not leasing brands. Saving looks it up immediately so the feedback
  # is one press rather than a seed file and a rake task.
  patch '/locations/:id' do
    require_leader!
    location = Location.find_by(id: params[:id]) or halt 404, 'No such location'
    location.update(address: params[:address].presence)
    geocode!(location) if location.address.present?

    redirect to('/locations')
  end

  # Re-check one place against the geocoder on demand. The Locations page
  # shows a verification state per row; this is the button next to the ones
  # that are not "verified", and the way to re-pin a place after its address
  # is corrected. No drift guard here — a human pressed it on purpose — but
  # the page shows the new state and coordinates immediately, so a bad result
  # is visible rather than silent.
  post '/locations/:id/verify' do
    require_leader!
    location = Location.find_by(id: params[:id]) or halt 404, 'No such location'
    geocode!(location)

    redirect to('/locations')
  end

  # --- the schedule ---------------------------------------------------------
  #
  # Events, Series and Sign-ups were three pages over the same rows. They are
  # one page now; the old paths redirect so existing links and bookmarks work.

  get '/schedule' do
    catch_up_on_occurrences
    phlex schedule_page(only: params[:only])
  end

  get('/series') { redirect to('/schedule') }
  get('/signups') { redirect to('/schedule') }
  get('/events') { redirect to('/schedule') }

  # Academic breaks live on the series page because that is the only thing they
  # affect. Shared across every series — the calendar belongs to the university.
  post '/breaks' do
    require_leader!
    academic_break = AcademicBreak.new(permitted(%w[name starts_on ends_on]))

    if academic_break.save
      # Occurrences generated before the break existed are now wrong; switch
      # off the upcoming ones rather than deleting anyone's roster.
      academic_break.disable_future_occurrences!
      redirect to('/schedule')
    else
      status 422
      phlex schedule_page(error: academic_break.errors.full_messages.to_sentence)
    end
  end

  delete '/breaks/:id' do
    require_leader!
    AcademicBreak.find_by(id: params[:id])&.destroy
    EventGenerator.call
    redirect to('/schedule')
  end

  get '/series/new' do
    require_leader!
    phlex SeriesForm.new(series: EventSeries.new(interval_weeks: 1, horizon_weeks: 3,
                                                 signup_lead_days: 3),
                         **form_collections, leader: leader?)
  end

  post '/series' do
    require_leader!
    series = EventSeries.new(series_params)
    if series.save
      EventGenerator.call(only: series)
      Signup::AutoSchedule.new.call
      redirect to("/series/#{series.id}")
    else
      status 422
      phlex SeriesForm.new(series: series, **form_collections, leader: leader?,
                           error: series.errors.full_messages.to_sentence)
    end
  end

  get '/series/:id' do
    series = EventSeries.find_by(id: params[:id]) or halt 404, 'No such series'
    phlex SeriesShow.new(
      series: series,
      upcoming: series.events.upcoming.chronological.to_a,
      past: series.events.past.order(start_time: :desc).limit(25).to_a,
      leader: leader?
    )
  end

  get '/series/:id/edit' do
    require_leader!
    series = EventSeries.find_by(id: params[:id]) or halt 404, 'No such series'
    phlex SeriesForm.new(series: series, **form_collections, leader: leader?)
  end

  patch '/series/:id' do
    require_leader!
    series = EventSeries.find_by(id: params[:id]) or halt 404, 'No such series'
    if series.update(series_params)
      unless series.disabled
        EventGenerator.call(only: series)
        Signup::AutoSchedule.new.call
      end
      redirect to("/series/#{series.id}")
    else
      status 422
      phlex SeriesForm.new(series: series, **form_collections, leader: leader?,
                           error: series.errors.full_messages.to_sentence)
    end
  end

  post '/series/:id/generate' do
    require_leader!
    series = EventSeries.find_by(id: params[:id]) or halt 404, 'No such series'
    EventGenerator.call(only: series)
    redirect to("/series/#{series.id}")
  end

  # Set one date's sign-up up from the calendar, and open it.
  #
  # Reaches past the three-week window the automation works to, which is the
  # point: the calendar shows five months, and a date you can see is a date you
  # should be able to prepare. Idempotent, so clicking the same day twice opens
  # the same post rather than making a second one.
  post '/schedule/:date/signup' do
    require_leader!
    date = Date.parse(params[:date].to_s) rescue halt(422, 'Not a date')
    post = Signup::AutoSchedule.new.ensure_for(date)
    halt 422, "Nothing is happening on #{date.strftime('%-d %b')}" if post.nil?

    redirect to("/signups/#{post.id}")
  end

  # Every emoji the picker can offer.
  #
  # Its own endpoint rather than inlined in the sign-up page: ~150KB, identical
  # for everyone, and most of the time nobody opens the picker at all. Cached
  # hard — the Unicode set does not change between page loads, and the server's
  # own emoji are in the ETag so adding one busts it.
  get '/emoji.json' do
    require_leader!
    emojis = Emoji.order(:name).to_a
    catalogue = Signup::EmojiCatalogue.all(emojis)

    etag Digest::MD5.hexdigest("#{catalogue.size}-#{emojis.map(&:discord_id).join(',')}")
    cache_control :private, max_age: 86_400
    content_type :json
    catalogue.to_json
  end

  # --- sign-up posts --------------------------------------------------------

  post '/signups' do
    require_leader!
    post = SignupPost.new(
      channel_id: params[:channel_id],
      service_date: params[:service_date].presence,
      created_by: current_user
    )
    halt 422, post.errors.full_messages.to_sentence unless post.save
    # Every event that day is already known, so fill the emoji rows in rather
    # than making someone pick each one out of a dropdown.
    Signup::OptionSeeder.new(post).call
    redirect to("/signups/#{post.id}")
  end

  # Re-fill after the ride date changes, or after an event is added to that day.
  get '/signups/:id' do
    post = find_signup(params[:id])
    # One emoji per pickup time, checked every time the page is opened rather
    # than only when the post was made. A time added or cancelled since then is
    # reflected here instead of drifting. No-ops unless the post is editable.
    Signup::OptionSeeder.new(post).call
    phlex signup_page(post.reload)
  end

  patch '/signups/:id' do
    require_leader!
    post = find_signup(params[:id])
    halt 409, 'This post has already been sent.' unless post.editable?

    attrs = permitted(%w[channel_id service_date post_at intro outro])
    if post.update(attrs)
      redirect to("/signups/#{post.id}")
    else
      status 422
      phlex signup_page(post, error: post.errors.full_messages.to_sentence)
    end
  end

  delete '/signups/:id' do
    require_leader!
    post = find_signup(params[:id])
    halt 409, 'This post has already been sent.' unless post.editable?

    post.destroy
    redirect to('/signups')
  end

  # The row's pickup time is not editable — it is what the row IS. What can
  # change is which emoji stands for it, and the line of text beside it.
  patch '/signups/:id/options/:option_id' do
    require_leader!
    post = find_signup(params[:id])
    halt 409, 'This post has already been sent.' unless post.editable?

    option = post.options.find(params[:option_id])
    option.label = params[:label].presence

    chosen = params[:emoji].presence || params[:emoji_pick].presence
    if chosen
      attrs = Signup::EmojiKey.parse(chosen)
      halt 422, "Could not read #{chosen.inspect} as an emoji." if attrs.nil?

      # Uniquely indexed on [signup_post_id, emoji_key]: without this an emoji
      # another time already uses is a 500 instead of a sentence.
      if post.options.any? { |other| other.id != option.id && other.emoji_key == attrs[:emoji_key] }
        halt 422, "#{chosen} is already used by another time on this sign-up."
      end

      option.assign_attributes(attrs)
    end

    if option.save
      redirect to("/signups/#{post.id}")
    else
      status 422
      phlex signup_page(post, error: option.errors.full_messages.to_sentence)
    end
  end

  post '/signups/:id/schedule' do
    require_leader!
    post = find_signup(params[:id])
    # Accept a send time given here, rather than only the one already saved by
    # the settings form. Typing a time and pressing Schedule without pressing
    # Save first used to discard it silently and answer "the post needs a send
    # time", which is a confusing thing to be told about a time you just typed.
    post.update(post_at: params[:post_at]) if params[:post_at].present? && post.editable?
    halt 422, 'Every option needs a ride, and the post needs a send time.' unless post.schedule!
    redirect to("/signups/#{post.id}")
  end

  # Send it on the next tick.
  #
  # Deliberately the same queue rather than a second path to Discord. The web
  # process has no gateway connection and config.ru keeps it that way, so this
  # can only ever be a row the bot picks up. `Publisher#claim` selects
  # `status = 'scheduled' AND post_at <= now()` under FOR UPDATE SKIP LOCKED,
  # so moving post_at to now makes it claimable while inheriting every existing
  # protection: the `posting` lease, stale recovery, and the unique
  # discord_message_id that is the last line of defence against a double post.
  post '/signups/:id/post-now' do
    require_leader!
    post = find_signup(params[:id])
    halt 409, 'This post has already been sent.' if post.posted? || post.status == 'posting'

    post.update(post_at: Time.zone.now)

    # A scheduled post cannot be scheduled again — `schedulable?` requires
    # `editable?`, which 'scheduled' is not. Moving its post_at is enough.
    if post.editable? && !post.schedule!
      halt 422, 'Every option needs a ride, and the post needs a channel.'
    end

    redirect to("/signups/#{post.id}")
  end

  post '/signups/:id/unschedule' do
    require_leader!
    find_signup(params[:id]).unschedule!
    redirect to("/signups/#{params[:id]}")
  end

  post '/signups/:id/close' do
    require_leader!
    find_signup(params[:id]).close!
    redirect to("/signups/#{params[:id]}")
  end

  post '/signups/:id/reopen' do
    require_leader!
    find_signup(params[:id]).reopen!
    redirect to("/signups/#{params[:id]}")
  end

  # Take a posted sign-up back down so it can be fixed and sent again.
  #
  # Only sets the flag. The bot deletes the message and then returns the post to
  # draft — the post deliberately stays `posted` until the message is really
  # gone, so a bot that is down cannot leave you editing a draft whose original
  # is still live in the channel.
  post '/signups/:id/revoke' do
    require_leader!
    post = find_signup(params[:id])
    halt 409, 'That sign-up has not been sent.' if post.discord_message_id.blank?

    post.update!(revoke_requested_at: Time.zone.now)
    redirect to("/signups/#{post.id}")
  end

  # Ask the bot for a sweep. It polls for this every 15 seconds.
  post '/signups/:id/resync' do
    require_leader!
    find_signup(params[:id]).update!(reconcile_requested_at: Time.zone.now)
    redirect to("/signups/#{params[:id]}")
  end

  # --- ride board ----------------------------------------------------------

  # The board for one occurrence. Without an id we pick the next upcoming one so
  # "/board" is a usable bookmark on a Sunday morning.
  get '/board' do
    event = find_event(params[:event_id]) || default_event
    halt 404, 'No upcoming events. Create one in Discord with /event create.' if event.nil?

    page = board_page(event)
    # The live filter re-fetches this route, so serve it the swappable fragment.
    (request.xhr? || params[:fragment] == '1') ? phlex(page.fragment) : phlex(page)
  end

  # Every mutation below re-renders the board and returns it as a fragment, so
  # the page swaps one div instead of reloading. Without JS the same routes still
  # work and just redirect back to the board.
  post '/board/:event_id/assign' do
    with_board do |event, history|
      ride = event.rides.riders.find(params[:ride_id])
      target = params[:driver_ride_id].presence && event.rides.drivers.find(params[:driver_ride_id])

      history.record([ride])
      ride.update!(
        driver_ride_id: target&.id,
        status: target ? 'assigned' : 'requested'
      )
    end
  end

  post '/board/:event_id/optimize' do
    with_board do |event, history|
      history.record(event.rides.unassigned.to_a)
      # Time-optimal via OR-Tools; falls back to the greedy zone matcher inside
      # itself, so the button works even if the solver never loads.
      Rides::Optimizer.call(RideBoard.new(event))
    end
  end

  post '/board/:event_id/undo' do
    with_board { |_event, history| history.undo! }
  end

  # Rider "not coming" and driver "not driving today" are the same toggle.
  post '/board/:event_id/toggle-out' do
    with_board do |event, history|
      ride = event.rides.find(params[:ride_id])
      history.record([ride])

      if ride.out?
        ride.update!(status: ride.driver_ride_id ? 'assigned' : 'requested')
      else
        ride.update!(status: ride.driver? ? 'cancelled' : 'no_show', driver_ride_id: nil)
      end
    end
  end

  patch '/board/:event_id/rides/:ride_id' do
    with_board do |event, _history|
      ride = event.rides.find(params[:ride_id])
      RideDetails.new(ride).apply(params)
    end
  end

  delete '/board/:event_id/rides/:ride_id' do
    with_board do |event, _history|
      event.rides.find(params[:ride_id]).destroy
    end
  end

  post '/board/:event_id/rides' do
    with_board do |event, _history|
      RideDetails.create_for(event, params)
    end
  end

  # Someone who is not in the Discord, riding with whoever brought them.
  post '/board/:event_id/guests' do
    halt 422, 'A plus-one needs a name' if params[:name].to_s.strip.empty?
    halt 422, 'Pick who they are coming with' if params[:host_ride_id].blank?

    with_board do |event, _history|
      RideDetails.create_guest(event, host_ride_id: params[:host_ride_id], name: params[:name])
    end
  end

  # Seats everyone who drives, in one press.
  #
  # Nothing ever created a driver: reactions arrive as riders because the emoji
  # does not say which someone meant, so every week began by adding the same
  # people by hand, one at a time, on every board. The app already knows who
  # they are — an active member with a seat count.
  post '/board/:event_id/drivers' do
    with_board do |event, _history|
      board = RideBoard.new(event)
      # The button says which tag it is adding, so obey that rather than the
      # day's default — the whole point of showing every tag is being able to
      # pick a different one.
      # Explicit ALL, never implicit. A request with no tag falls back to the
      # day's own, so a stale form or a missing field adds the usual handful
      # rather than the entire roster.
      chosen = if params[:tag] == Components::BoardShell::ALL_DRIVERS
                 board.addable_drivers
               elsif params[:tag].present?
                 board.drivers_tagged(User.canonical_tag(params[:tag]))
               else
                 board.regular_drivers
               end

      chosen.each do |driver|
        # Symbol keys: `create_for` reads `params[:user_id]`, and Sinatra's
        # indifferent access does not come with a plain Hash.
        RideDetails.create_for(event, user_id: driver.id, role: 'driver')
      end
    end
  end

  # Ask the bot to re-read this date's sign-up reactions. It polls for the
  # request every 15 seconds, so nothing has changed by the time this renders —
  # the board shows "syncing…" until the sweep lands.
  #
  # The web process has no Discord connection by design, so this is a flag on
  # the post rather than a fetch. Scoped to the whole service DATE, not this one
  # occurrence: a Sunday's two services share a sign-up post.
  post '/board/:event_id/resync' do
    with_board do |event, _history|
      SignupPost.tracking
                .where(service_date: event.occurrence_date || event.start_time&.to_date)
                .update_all(reconcile_requested_at: Time.zone.now)
    end
  end

  # Queue DMs to drivers. The roster is snapshotted here, in this request, so
  # what goes out is what the coordinator was looking at — the bot only renders
  # and delivers.
  post '/board/:event_id/dispatch' do
    require_leader!
    event = find_event(params[:event_id]) or halt 404, 'No such event'
    # The buttons are gone from a finished board, but a tab left open since
    # Sunday still has them. Refuse here too: a DM about a lift that already
    # happened is confusing at best, and the board it was sent from looks
    # identical to this week's.
    halt 422, 'That event has already happened — nothing to send.' if event.past?

    dispatch = DispatchPlanner.new(
      RideBoard.new(event),
      requested_by: current_user,
      scope: params[:scope].to_s
    ).call

    halt 422, 'Nobody to send to.' if dispatch.nil?
    render_board(event)
  end

  # The routes, drawn. Answers "does this look sane?", which a column of names
  # cannot — and shows what the optimizer decided, which is worth seeing before
  # twenty people are told to stand outside.
  get '/board/:event_id/map' do
    event = find_event(params[:event_id]) or halt 404, 'No such event'
    board = RideBoard.new(event)
    phlex BoardMap.new(board: board, map: RouteMap.new(board),
                       tiles: Abid.map_tiles, leader: leader?)
  end

  get '/events/:event_id/dispatches' do
    event = find_event(params[:event_id]) or halt 404, 'No such event'
    dispatches = event.dispatches.includes(:requested_by, messages: :user).recent.to_a
    phlex DispatchLog.new(event: event, dispatches: dispatches, leader: leader?)
  end

  get '/board/:event_id.csv' do
    event = find_event(params[:event_id]) or halt 404
    content_type 'text/csv'
    attachment "rides-#{event.start_time&.strftime('%Y-%m-%d') || event.id}.csv"
    RideBoardCsv.new(RideBoard.new(event)).to_csv
  end

  private

  PUBLIC_PATHS = ['/login'].freeze

  def current_user
    return @current_user if defined?(@current_user)
    @current_user = session[:user_id] && User.find_by(id: session[:user_id])
  end

  def leader?
    !!current_user&.leader
  end

  def ensure_logged_in
    return if PUBLIC_PATHS.include?(request.path_info)

    # A stale session cookie pointing at a deleted user (someone left the server)
    # should log out cleanly rather than 500 further down the request.
    return if current_user

    session.clear
    redirect to('/login')
  end

  # Guard for anything that edits data. The bot checks `leader` per command; the
  # web side previously checked only "is logged in".
  def require_leader!
    halt 403, 'Leaders only' unless leader?
  end

  def find_event(id)
    return nil if id.blank?
    Event.find_by(id: id)
  end

  # "+ slot" on the board links here with ?date=. Default to an hour after the
  # last slot already on that day — adding a third Sunday service to a 9:30 and
  # a 10:30 almost always means 11:30, and a bare date would otherwise land the
  # datetime field on midnight.
  # Where rides go. Everything goes to the same place, so asking every time is
  # a question with one answer.
  #
  # Read off the series rather than hardcoded, so it follows the day the venue
  # moves instead of quietly pre-selecting the old one.
  def default_venue_id
    EventSeries.where.not(location_id: nil)
               .group(:location_id).count
               .max_by { |_, count| count }&.first
  end

  def prefilled_start_time
    date = Date.parse(params[:date].to_s)
    last = Event.active.where(start_time: date.all_day).maximum(:start_time)
    last ? last + 1.hour : Time.zone.local(date.year, date.month, date.day, 9, 0)
  rescue Date::Error, TypeError
    nil
  end

  # Rides are preloaded because EventTable counts riders and drivers per row.

  # One date's worth of the schedule: its occurrences, and the single sign-up
  # post that covers them.
  ScheduleDay = Struct.new(:date, :events, :post, keyword_init: true) do
    def channel_id = events.filter_map(&:channel_id).first
  end

  # Recurring events keep going on their own. The bot materialises occurrences
  # once a day — but generation lived ONLY in the bot, so a bot that was off
  # meant a schedule that quietly stopped, and the fix was a "Generate now"
  # button the coordinator had to know to press. That is a job for the machine.
  #
  # Opening the schedule now does it too, so the page can never show you a gap
  # it could have filled itself.
  #
  # The gate is "has the lookahead shrunk", not "did we run today":
  # `last_generated_on` holds the FURTHEST occurrence generated, not the date of
  # the run. Comparing it to today would sit idle until the horizon had already
  # run out — the exact gap this is here to prevent. Compared instead against
  # the series' own horizon, so a 3-week series regenerates once it is down to
  # its last two weeks. One query on every other view.
  #
  # Both paths take the same advisory lock inside EventGenerator, so a web
  # request and the bot's tick cannot duplicate each other's work.
  def catch_up_on_occurrences
    thin = EventSeries.generatable.where(
      'last_generated_on IS NULL OR last_generated_on < CURRENT_DATE + ((horizon_weeks - 1) * 7)'
    )
    return unless thin.exists?

    EventGenerator.call
    Signup::AutoSchedule.new.call
  rescue StandardError => e
    # Never let this break the page — it is a background chore that happens to
    # run in the foreground.
    warn "catch-up generation failed: #{e.class}: #{e.message}"
  end

  # Five months, matching the calendar beside the list. It used to be six weeks,
  # which is why one-off events further out — a retreat in January — were in the
  # database and simply never fetched: they were not missing, they were not
  # asked for.
  CALENDAR_MONTHS = 5

  def schedule_page(error: nil, months: CALENDAR_MONTHS, only: nil)
    events = Event.includes(:location, :series, :channel, rides: :user)
                  .where(start_time: Time.zone.now..(Time.zone.today + months.months).end_of_day)
                  .chronological.to_a
    # Five months of a weekly schedule is ~40 near-identical Fridays and
    # Sundays, and the one retreat in the middle is what you were looking for.
    # Filtering drops the whole date when nothing one-off happens on it, so the
    # calendar thins out too rather than showing tinted days with empty cards.
    only_one_off = only.to_s == 'one_off'
    events = events.reject(&:recurring?) if only_one_off
    by_date = events.group_by { |event| event.start_time.to_date }

    posts = SignupPost.includes(:options)
                      .where(service_date: by_date.keys)
                      .index_by(&:service_date)

    Schedule.new(
      dates: by_date.sort_by(&:first).map { |date, day_events|
        ScheduleDay.new(date: date, events: day_events, post: posts[date])
      },
      series: EventSeries.order(:weekday, :start_time_of_day).to_a,
      breaks: AcademicBreak.chronological.to_a,
      past: Event.past.includes(rides: :user).order(start_time: :desc).limit(25).to_a,
      only_one_off: only_one_off,
      leader: leader?,
      error: error
    )
  end

  def find_signup(id)
    SignupPost.includes(:channel, options: :event).find_by(id: id) or halt 404, 'No such sign-up post'
  end

  def signup_page(post, error: nil)
    SignupShow.new(
      post: post,
      channels: Channel.for_rides.order(:name).to_a,
      # The server's own emoji, synced by the bot. Previously reachable only by
      # typing :name: and knowing it existed.
      server_emojis: Emoji.order(:name).to_a,
      leader: leader?,
      error: error
    )
  end

  # Upcoming ride dates with no sign-up post yet. Delegated so the list the
  # page offers and the list the automation acts on cannot disagree.
  def dates_needing_signup(weeks: 3)
    Signup::AutoSchedule.new(horizon_weeks: weeks).uncovered_dates
  end

  def users_for(filter, query)
    scope = User.includes(:location).by_name
    scope = scope.search(query) if query.present?

    # Everything except Non-Active is a cut of the active roster.
    case filter
    when 'other' then scope.other
    when 'drivers' then scope.active.drivers
    when 'riders' then scope.active.riders
    when 'missing' then scope.active.missing_details
    else scope.active
    end.to_a
  end

  # Counts ignore the search box: the tabs should say how many drivers exist,
  # not how many match what is currently typed.
  def user_counts
    {
      'active' => User.active.count,
      'drivers' => User.active.drivers.count,
      'riders' => User.active.riders.count,
      'missing' => User.active.missing_details.count,
      'other' => User.other.count
    }
  end

  USER_FIELDS = %w[name phone location_id class_location_id capacity grad_year].freeze

  # Checkboxes are absent from the params when unticked, so both booleans are
  # read positionally rather than through `permitted` — each has a hidden '0'
  # in front of it in the form.
  # The sentinel the "Other — add a new place…" option submits. Not an id, so it
  # can never collide with one.
  NEW_LOCATION = '__new__'.freeze

  # Comma or newline separated, straight out of a text box. Parsed here rather
  # than accepting an array param, so the form stays a single field somebody can
  # type into — which is what makes inventing a new tag cost nothing.
  def parse_tags(raw)
    raw.to_s.split(/[,\n]/).filter_map { |t| User.canonical_tag(t) }.uniq(&:downcase)
  end

  def user_params
    attrs = permitted(USER_FIELDS).merge(
      'leader' => params[:leader] == '1',
      'active' => params[:active] == '1'
    )
    attrs['tags'] = parse_tags(params[:tags]) if params.key?('tags')

    # Resolved here rather than by bouncing through POST /locations, so adding a
    # place and saving the member is one press and a half-filled form is never
    # thrown away.
    { 'location_id' => 'new_location', 'class_location_id' => 'new_class_location' }
      .each do |field, prefix|
        next unless attrs[field] == NEW_LOCATION

        place = find_or_create_location(
          name: params[:"#{prefix}_name"],
          zone: params[:"#{prefix}_zone"],
          address: params[:"#{prefix}_address"]
        )
        # A blank name leaves the field untouched rather than clearing it: the
        # member's existing address is not collateral for a mis-click.
        place ? attrs[field] = place.id : attrs.delete(field)
      end

    attrs
  end

  def user_page(user, error: nil)
    UserShow.new(
      user: user,
      locations: Location.order(:name).to_a,
      known_tags: User.known_tags,
      load: DriverLoad.new,
      history: user.rides.includes(:event).joins(:event)
                   .where.not(events: { start_time: nil })
                   .order('events.start_time DESC').limit(12).to_a,
      leader: leader?,
      error: error
    )
  end

  # Two grouped counts rather than N per-row queries.
  # Reused by the Locations page and by the member form's "Other…" option.
  # Matching an existing name case-insensitively is deliberate: someone adding
  # "hilltop" when "Hilltop Apartments" exists wants that place, not a second
  # row that splits everyone who lives there across two entries.
  #
  # @return [Location, nil] nil only when the name is blank
  def find_or_create_location(name:, zone: nil, address: nil)
    name = name.to_s.strip
    return nil if name.blank?

    existing = Location.find_by('lower(name) = ?', name.downcase)
    return existing if existing

    location = Location.new(name: name, zone: zone.presence, address: address.presence)
    return nil unless location.save

    geocode!(location) if location.address.present?
    location
  end

  # Best-effort and never blocking: Nominatim is a third party, and a failed
  # lookup must still keep the address that was typed.
  # Look the place up and record HOW well it resolved, not just where.
  #
  # A verified hit (rooftop / interpolated) also takes Google's formatted
  # street address, because that is a better thing to hand a driver than
  # whatever was typed — "Village West" becomes "2053 Willowbrook Dr". An
  # approximate hit keeps the human's address text: Google's guess at the
  # coordinates is still worth having, but its guess at the address is not
  # worth overwriting a real one with.
  def geocode!(location)
    result = begin
      Map.new.geocode(location.geocode_query)
    rescue StandardError => e
      warn "geocoding #{location.name} failed: #{e.class}: #{e.message}"
      {}
    end
    return if result[:lat].blank?

    attrs = { lat: result[:lat], lon: result[:lon],
              verification: result[:verification], verified_at: Time.zone.now,
              place_id: result[:place_id] }
    attrs[:address] = result[:address] if result[:address].present? &&
                                          Location::VERIFIED.include?(result[:verification])
    location.update(attrs)
  end

  def describe_usage(counts)
    [
      ("#{counts[:users]} live there" if counts[:users].to_i.positive?),
      ("#{counts[:classes]} have class there" if counts[:classes].to_i.positive?),
      ("#{counts[:rides]} pickups" if counts[:rides].to_i.positive?),
      ("#{counts[:events]} events" if counts[:events].to_i.positive?)
    ].compact.join(', ')
  end

  # Everything that points at a location. `classes` is not decoration: a place
  # can be someone's Friday last-class pickup and nothing else, and leaving it
  # out here would show that location as unused and let it be deleted out from
  # under them.
  def location_usage
    users = User.where.not(location_id: nil).group(:location_id).count
    classes = User.where.not(class_location_id: nil).group(:class_location_id).count
    rides = Ride.where.not(pickup_location_id: nil).group(:pickup_location_id).count
    events = Event.where.not(location_id: nil).group(:location_id).count

    (users.keys | classes.keys | rides.keys | events.keys).to_h do |id|
      [id, { users: users[id].to_i, classes: classes[id].to_i,
             rides: rides[id].to_i, events: events[id].to_i }]
    end
  end

  def form_collections
    { channels: Channel.for_rides.order(:name).to_a, locations: Location.order(:name).to_a }
  end

  # No `section`: a pickup time is identified by its time, which display_name
  # now says outright. No `end_time`: a ride is over when its day is, so there
  # is nothing for it to decide.
  EVENT_FIELDS = %w[name start_time pickup_source channel_id location_id].freeze

  SERIES_FIELDS = %w[name weekday interval_weeks start_time_of_day end_time_of_day
                     signup_lead_days signup_post_time signup_outro pickup_source channel_id location_id
                     starts_on ends_on horizon_weeks].freeze

  def event_params
    permitted(EVENT_FIELDS).merge('disabled' => params[:disabled] == '1')
  end

  def series_params
    permitted(SERIES_FIELDS).merge('disabled' => params[:disabled] == '1')
  end

  # Blank strings from an HTML form must become NULL, not "", or a blank
  # datetime-local field would fail to cast and a blank select would write an
  # empty foreign key.
  def permitted(fields)
    params.slice(*fields).to_h.transform_values { |value| value.is_a?(String) ? value.presence : value }
  end

  def default_event
    Event.active.upcoming.chronological.first || Event.active.chronological.last
  end

  def board_page(event)
    Board.new(
      board: RideBoard.new(
        event,
        query: params[:q],
        selected_ride_id: params[:sel],
        focus_ride_id: params[:focus]
      ),
      can_undo: AssignmentHistory.new(session, event).any?,
      leader: leader?,
      tab: params[:tab] == 'roster' ? :roster : :details
    )
  end

  # Shared wrapper for board mutations: authorise, run the change, then hand back
  # a freshly rendered board.
  def with_board
    require_leader!
    event = find_event(params[:event_id]) or halt 404, 'No such event'
    history = AssignmentHistory.new(session, event)

    yield event, history

    render_board(event)
  rescue ActiveRecord::RecordNotFound
    halt 404, 'No such ride'
  rescue ActiveRecord::RecordInvalid => e
    halt 422, e.record.errors.full_messages.to_sentence
  end

  def render_board(event)
    if request.xhr? || params[:fragment] == '1'
      phlex board_page(event).fragment
    else
      redirect back_to_board(event)
    end
  end

  def back_to_board(event)
    query = { event_id: event.id, q: params[:q], tab: params[:tab], focus: params[:focus] }.compact_blank
    to("/board?#{URI.encode_www_form(query)}")
  end
end
