# Builds a Dispatch and its per-driver messages from the board as it looks
# right now.
#
# Runs in the WEB process, at the moment the coordinator presses send. The
# roster snapshot is taken here, atomically, so what goes out is what they were
# looking at — not whatever the board has drifted to by the time the bot picks
# the job up. The bot only renders and delivers.
class DispatchPlanner
  def initialize(board, requested_by: nil, scope: 'changed')
    @board = board
    @event = board.event
    @requested_by = requested_by
    @scope = Dispatch::SCOPES.include?(scope.to_s) ? scope.to_s : 'changed'
  end

  # @return [Dispatch, nil] nil when there is nobody to message
  def call
    targets = recipients
    return nil if targets.empty?

    Dispatch.transaction do
      dispatch = Dispatch.create!(
        event: @event,
        requested_by: @requested_by,
        scope: @scope,
        attempt: next_attempt,
        status: 'queued',
        requested_at: Time.zone.now,
        board_snapshot: board_snapshot
      )

      @board.cars.each do |car|
        build_message(dispatch, car, skipped: !targets.include?(car.id))
      end

      dispatch
    end
  end

  private

  def status
    @status ||= DispatchStatus.new(@board)
  end

  def recipients
    rides = @scope == 'all' ? @board.driver_rides.select(&:active?) : status.stale_driver_rides
    rides.map(&:id)
  end

  def next_attempt
    @event.dispatches.maximum(:attempt).to_i + 1
  end

  def board_snapshot
    readiness = DispatchReadiness.new(@board)
    {
      'cars' => @board.cars.size,
      'seated' => @board.seated_count,
      'waiting' => @board.pool_count,
      'seats_left' => @board.seats_left,
      'findings' => readiness.to_keys,
      'ready' => readiness.ready?
    }
  end

  # Skipped drivers still get a row, so attempt N is a complete picture of the
  # board at that moment — you can answer "was Tobin in that dispatch?" without
  # reconstructing it.
  def build_message(dispatch, car, skipped:)
    ride = car.ride
    roster = roster_for(car)

    dispatch.messages.create!(
      driver_ride: ride,
      user: ride.user,
      discord_id: ride.user&.discord_id,
      driver_name: ride.display_name,
      status: skipped ? 'skipped' : 'pending',
      roster: roster,
      roster_digest: DispatchDigest.for(ride, car.passengers, @event),
      route_url: roster['maps_url']
    )
  end

  def roster_for(car)
    plan = RoutePlanner.new(car, event: @event).call

    {
      'event' => {
        'id' => @event.id,
        # `name`, not display_name: the briefing headline already prints the
        # date and time right after it, and display_name now carries the time
        # too — "**Abide — 6:30 PM** — Friday 18 Sep, 6:30 PM".
        'name' => @event.name,
        'starts_at' => @event.start_time&.iso8601,
        'location' => @event.location && { 'name' => @event.location.name }
      },
      'driver' => {
        'ride_id' => car.id,
        'user_id' => car.ride.user_id,
        'name' => car.name,
        'seats' => car.seats
      },
      # Ordered by the plan, so the DM lists people in pickup order.
      'riders' => plan.pickups.map { |stop| rider_entry(car, stop) },
      # A driver's own plus-ones: in the car from the start, so not a stop.
      'with_driver' => car.passengers.select(&:riding_from_the_start?).map(&:display_name),
      'maps_url' => plan.maps_url,
      'truncated' => plan.truncated
    }
  end

  def rider_entry(car, stop)
    ride = car.passengers.find { |p| p.id == stop.ride_id }
    {
      'ride_id' => stop.ride_id,
      'user_id' => ride&.user_id,
      'name' => stop.name,
      # The Discord handle, so a driver can reach them where the message they
      # are reading already is. A phone number is the better channel at 6:15am
      # outside a locked apartment block; a handle is the one that works when
      # somebody never filled their number in, which is most people.
      'username' => ride&.user&.username,
      'pickup' => stop.label,
      'zone' => ride&.zone,
      'phone' => ride&.user&.phone,
      'note' => ride&.note,
      # A plus-one has no Discord and no phone on file: say who to ask.
      'guest_of' => (ride.host_ride&.display_name if ride&.guest?)
    }
  end
end
