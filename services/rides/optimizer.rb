module Rides
  # Time-optimal seat assignment — what the Auto-fill button and the bot's
  # late-rider sweep both call.
  #
  # A capacitated vehicle-routing problem: each car starts where its driver is
  # (home, or last class on a Friday), collects riders, and everyone ends at the
  # venue. The objective is total driving seconds.
  #
  # Two invariants, and they are the design:
  #
  #   Nobody a human or a dispatch has committed to ever moves. Two kinds of
  #   seating are sacred: any rider in a car whose driver has been told
  #   (queued/sent/confirmed), and any rider a coordinator placed by hand.
  #   The optimizer's OWN pre-dispatch placements are neither — it may revise
  #   itself freely until a driver has been messaged, which is what lets a
  #   re-press fix a layout the constraints have since outlawed. The tell is
  #   pickup_position: the optimizer always writes one, hand-seating never
  #   does, and a manual re-drag clears it.
  #
  #   The pool is droppable, the seated are not. Over-capacity leaves people
  #   visibly in the queue rather than failing the solve or evicting someone.
  #
  # Falls back to the greedy zone AutoFiller on ANY failure — gem missing,
  # venue unlocatable, solver infeasible — because this button gets pressed on
  # Sunday mornings and must never 500.
  class Optimizer
    Result = Struct.new(:seated, :dropped, :reordered, :engine, keyword_init: true)

    # Dropping a mandatory-ish visit must always beat a bad route, so the
    # penalty dwarfs any real drive: 8 hours.
    DROP_PENALTY = 8 * 3600
    # Pulling over, loading, seatbelts, going again. Without this a stop is
    # free and the cheapest plan is one car snaking through every pickup —
    # total driving time genuinely IS lowest that way, and it is still the
    # wrong answer, because minutes-per-stop is what the sheet coordinator
    # was implicitly pricing in.
    STOP_SECONDS = 90
    # The most time one car may spend COLLECTING — travel between pickups plus
    # loading, not the shared drive to the venue. A campus cluster of four is a
    # few minutes; a dozen-stop sweep across town blows past this and spills to
    # another car. Deliberately not the whole route: the venue haul is fixed
    # for everyone and is not a snake.
    MAX_ROUTE_SECONDS = 20 * 60
    # Mild pressure to even routes out once the hard cap is satisfied. Small
    # on purpose: 3 means a minute of imbalance costs three minutes of
    # objective, enough to spread riders without chasing perfect symmetry.
    SPAN_COST = 3
    # How far somebody can reasonably be asked to walk to a meeting-point
    # vehicle: ~15 minutes at a student walking pace, as the crow flies.
    WALK_METERS = 1200
    # Persist an improvement-only re-solve just for beating the old routes by
    # noise? No — two minutes or it did not happen. Keeps the button idempotent
    # even though a time-limited metaheuristic is not deterministic.
    IMPROVEMENT_FLOOR = 120

    def self.call(...)
      new(...).call
    end

    def initialize(board, matrix: nil)
      @board = board
      @event = board.event
      @matrix = matrix || TravelMatrix.new
    end

    # @return [Result] engine: :or_tools or :greedy (the fallback)
    def call
      return Result.new(seated: 0, dropped: 0, reordered: 0, engine: :or_tools) if cars.empty?

      walked = fill_meeting_points
      result = solve
      Result.new(seated: result.seated + walked, dropped: result.dropped,
                 reordered: result.reordered, engine: result.engine)
    rescue StandardError, LoadError => e
      warn "optimizer fell back to greedy: #{e.class}: #{e.message}"
      seated = AutoFiller.new(@event).call
      Result.new(seated: seated, dropped: 0, reordered: 0, engine: :greedy)
    end

    private

    # Meeting-point vehicles fill FIRST, before any driving is planned. Their
    # riders walk over, so a seat there costs zero driving — the cheapest seat
    # on the board by definition, which is exactly why the coordinator wants
    # the van packed before the cars start routing.
    #
    # Nearest-first within walking range, so when the van cannot take everyone
    # the people left to the cars are the ones a car was going to pass anyway.
    # Skips frozen vehicles: a van whose driver has been dispatched keeps its
    # roster like any other sent car.
    def fill_meeting_points
      walked = 0
      meeting_cars.each do |car|
        next if %i[queued sent confirmed].include?(@board.dispatch_status.state_for(car.ride))

        spot = @matrix.point_for(car.ride)
        next if spot.nil?

        free = car.seats.to_i - car.passengers.size
        next if free <= 0

        # Only riders whose pickup has REAL coordinates. Walking is a hard
        # physical constraint, and a rider whose location is unknown gets
        # placed at their zone's centroid — which sits ~200m from Windsor and
        # made people whose actual pickup (Mechanical Engineering, Lilly) is
        # far away look like a 3-minute walk. A centroid is a fine guess for a
        # soft driving cost; it must never send someone on an impossible walk.
        # The tell is point.location_id: a real location carries one, a
        # centroid does not.
        candidates = pool.filter_map do |ride|
          point = @matrix.point_for(ride)
          next if point.nil? || point.location_id.nil?

          meters = straight_line_meters(spot, point)
          [ride, meters] if meters <= WALK_METERS
        end

        position = stops_of(car).size
        candidates.sort_by { |_, meters| meters }.each do |ride, _|
          need = party(ride)
          next if need > free

          ride.update!(driver_ride_id: car.id, status: 'assigned', pickup_position: position)
          free -= need
          position += 1
          walked += need
        end
      end
      reset_board_state if walked.positive?
      walked
    end

    def meeting_cars
      cars.select { |car| car.ride.meet_at_pickup }
    end

    def straight_line_meters(a, b)
      dy = (a.lat - b.lat) * 111_000
      dx = (a.lon - b.lon) * 111_000 * Math.cos(a.lat * Math::PI / 180)
      Math.sqrt((dx * dx) + (dy * dy))
    end

    # The pre-pass changed who is seated, so every memoised view of the board
    # is stale.
    def reset_board_state
      @cars = @pool = @seated = @rides_by_id = nil
      @board = RideBoard.new(@event)
    end

    def cars
      @cars ||= @board.cars
    end

    # Plus-ones (issue #22) ride with whoever brought them, so they are never
    # routed on their own: the host is one stop that needs 1 + guests seats,
    # and Ride#carry_guests moves them the moment the host is seated. That is
    # what keeps a group together and a car from being overfilled.
    def pool
      @pool ||= @board.pool.reject { |ride| follower?(ride) }
    end

    def seated
      @seated ||= cars.flat_map { |car| stops_of(car).map { |p| [p, car] } }
    end

    # A car's passengers who are their own stop — not plus-ones riding along.
    def stops_of(car)
      car.passengers.reject { |p| follower?(p) }
    end

    def rides_by_id
      @rides_by_id ||= @board.rides.index_by(&:id)
    end

    def follower?(ride)
      return false unless ride.guest? && ride.host_ride_id

      host = rides_by_id[ride.host_ride_id]
      host.present? && host.active?
    end

    # Seats this rider needs: themselves plus anyone they brought.
    def party(ride)
      1 + @board.rides.count { |g| g.host_ride_id == ride.id && g.guest? && g.active? }
    end

    # Seats already taken by a driver's own plus-ones, who are in the car from
    # the start and so are nobody's stop.
    def onboard(car)
      car.passengers.count { |p| follower?(p) && p.host_ride_id == car.id }
    end

    def venue_point
      @venue_point ||= begin
        venue = @event.location
        raise 'event has no locatable venue' unless venue&.coords?

        @matrix.point_for(venue)
      end
    end

    def solve
      require "or-tools"

      # Meeting-point vehicles do not drive routes — whoever walked to them is
      # settled, and their remaining seats are not fillable by driving.
      driving = cars.reject { |car| car.ride.meet_at_pickup }
      return Result.new(seated: 0, dropped: pool.size, reordered: 0, engine: :or_tools) if driving.empty?

      riders = seated.reject { |_, car| car.ride.meet_at_pickup }.map(&:first) + pool
      rider_points = riders.map { |ride| @matrix.point_for(ride) }
      driver_points = driving.map { |car| @matrix.point_for(car.ride) || venue_point }

      # A rider the matrix cannot place at all cannot be routed; they stay in
      # the pool rather than being seated somewhere arbitrary.
      routable = riders.each_index.select { |i| rider_points[i] }
      unroutable = riders.size - routable.size

      # Node layout: routable riders, then one start per vehicle, venue last.
      points = routable.map { |i| rider_points[i] } + driver_points + [venue_point]
      @matrix.warm(points)

      rider_count = routable.size
      venue_node = points.size - 1
      starts = Array.new(driving.size) { |v| rider_count + v }
      ends = Array.new(driving.size, venue_node)

      manager = ORTools::RoutingIndexManager.new(points.size, driving.size, starts, ends)
      routing = ORTools::RoutingModel.new(manager)

      # Real driver starts — the ones whose outbound leg is a fact worth paying
      # for. A no-location driver is modelled at the venue, so charging their
      # "outbound" would be charging the 15-minute haul backwards.
      real_start = (0...driving.size).select { |v| driving[v].ride.pickup&.coords? }
                                     .map { |v| rider_count + v }.to_set

      # Minimize the DETOUR, not the drive everyone makes anyway.
      #
      # This is the fix for "why does it cram everyone into one car" and "why a
      # cap at all". The old objective counted each car's shared haul to the
      # church, so fewer cars meant a lower number and the snake genuinely won
      # — the cap was the only thing prying riders back out. Drop the haul (and
      # a phantom driver's outbound) and a spare driver costs nothing to use,
      # so the optimizer spreads riders to whoever is already passing them.
      # Distribution becomes optimal, not enforced.
      cost = routing.register_transit_callback(lambda do |from, to|
        f = manager.index_to_node(from)
        t = manager.index_to_node(to)
        stop = f < rider_count ? STOP_SECONDS : 0
        # The final leg home is shared and fixed; a phantom driver's outbound
        # is fictional. Neither is a detour.
        next stop if t == venue_node
        next stop if f >= rider_count && !real_start.include?(f)

        @matrix.seconds(points[f], points[t]) + stop
      end)
      routing.set_arc_cost_evaluator_of_all_vehicles(cost)

      # The cap measures the PICKUP PHASE only — travel and loading between one
      # pickup and the next — never the driver's outbound leg nor the shared
      # final haul to the venue.
      #
      # This is the correction to a bug the user caught: the church is ~15
      # minutes from campus, so a cap on TOTAL route time was spent almost
      # entirely on that unavoidable haul, and started refusing riders even
      # with 23 empty seats. Worse, a driver with no address is modelled as
      # starting AT the venue, so collecting one campus rider was a 30-minute
      # round trip that hit the cap alone — and those cars sat empty.
      #
      # "Don't snake" means "don't string too many pickups together", which is
      # exactly the pickup-phase span. The venue is far for everyone; that is
      # geography, not a route to shorten.
      # A backstop, no longer the mechanism. With the haul out of the objective
      # the optimizer distributes on its own, so this only rules out a route so
      # long nobody would arrive — measured, like the objective, on the pickup
      # phase alone. The span cost nudges routes even once that is satisfied.
      pickup_time = routing.register_transit_callback(lambda do |from, to|
        f = manager.index_to_node(from)
        t = manager.index_to_node(to)
        next 0 if f >= rider_count
        next STOP_SECONDS if t == venue_node

        @matrix.seconds(points[f], points[t]) + STOP_SECONDS
      end)
      routing.add_dimension(pickup_time, 0, MAX_ROUTE_SECONDS, true, 'pickup')
      routing.mutable_dimension('pickup').set_global_span_cost_coefficient(SPAN_COST)

      parties = routable.map { |i| party(riders[i]) }
      demand = routing.register_unary_transit_callback(
        ->(index) { (node = manager.index_to_node(index)) < rider_count ? parties[node] : 0 }
      )
      capacities = driving.map do |car|
        seated_need = stops_of(car).sum { |p| party(p) }
        [car.seats.to_i - onboard(car), seated_need].max
      end
      routing.add_dimension_with_vehicle_capacity(demand, 0, capacities, true, 'seats')

      frozen_cars = driving.each_index.select do |v|
        %i[queued sent confirmed].include?(@board.dispatch_status.state_for(driving[v].ride))
      end.to_set

      pinned = {}
      movable_but_seated = []
      seated.reject { |_, car| car.ride.meet_at_pickup }.each do |ride, car|
        vehicle = driving.index(car)
        if frozen_cars.include?(vehicle) || ride.pickup_position.nil?
          pinned[ride.id] = vehicle
        else
          # The optimizer's own pre-dispatch placement: must stay seated
          # somewhere, but not owed this particular car.
          movable_but_seated << ride.id
        end
      end

      routable.each_with_index do |rider_i, node|
        index = manager.node_to_index(node)
        ride = riders[rider_i]
        if (vehicle = pinned[ride.id])
          routing.set_allowed_vehicles_for_index([vehicle], index)
        elsif !movable_but_seated.include?(ride.id)
          # Pool: seat them if the seats and the clock allow, else leave them
          # where the coordinator can see them.
          routing.add_disjunction([index], DROP_PENALTY)
        end
      end

      search = ORTools.default_routing_search_parameters
      search.first_solution_strategy = :path_cheapest_arc
      search.local_search_metaheuristic = :guided_local_search
      search.time_limit = 2

      solution = routing.solve_with_parameters(search)
      raise 'no feasible assignment' if solution.nil?

      routes = extract_routes(routing, manager, solution, riders, routable, rider_count, driving)
      persist(routes, unroutable)
    end

    def extract_routes(routing, manager, solution, riders, routable, rider_count, driving)
      driving.each_index.map do |vehicle|
        order = []
        index = routing.start(vehicle)
        until routing.end?(index)
          node = manager.index_to_node(index)
          order << riders[routable[node]] if node < rider_count
          index = solution.value(routing.next_var(index))
        end
        [driving[vehicle], order]
      end
    end

    # The guard that makes the button safe to lean on: a solve that seats
    # nobody new only rewrites pickup orders when it found a real improvement,
    # so pressing Auto-fill twice in a row changes nothing.
    def persist(routes, unroutable)
      newly = routes.sum { |car, order| order.select { |ride| ride.driver_ride_id != car.id }.sum { |ride| party(ride) } }
      improvement = previous_cost - proposed_cost(routes)

      if newly.zero? && improvement < IMPROVEMENT_FLOOR && !current_routes_overlong?
        return Result.new(seated: 0, dropped: pool.size + unroutable, reordered: 0, engine: :or_tools)
      end

      reordered = 0
      Ride.transaction do
        routes.each do |car, order|
          order.each_with_index do |ride, position|
            if ride.driver_ride_id != car.id
              ride.update!(driver_ride_id: car.id, status: 'assigned', pickup_position: position)
            elsif ride.pickup_position != position
              ride.update!(pickup_position: position)
              reordered += 1
            end
          end
        end
      end

      Result.new(seated: newly, dropped: pool.size - newly + unroutable,
                 reordered: reordered, engine: :or_tools)
    end

    # The idempotence guard must not preserve a layout the constraints now
    # forbid: after the route-length cap was added, boards optimized under the
    # old objective sat in 26-stop snakes that a re-press "improved" by zero
    # total seconds — and so refused to fix.
    def current_routes_overlong?
      cars.reject { |c| c.ride.meet_at_pickup }.any? do |car|
        stops = stops_of(car).sort_by { |p| [p.pickup_position || 1 << 30, p.display_name.to_s] }
        pickup_phase_seconds(car, stops) > MAX_ROUTE_SECONDS
      end
    end

    # The same measure the cap uses: between-pickup travel plus a stop each,
    # with neither the driver's outbound leg nor the venue haul.
    def pickup_phase_seconds(car, stops)
      here = nil
      total = 0
      stops.each do |ride|
        there = @matrix.point_for(ride) or next
        total += @matrix.seconds(here, there) if here
        total += STOP_SECONDS
        here = there
      end
      total
    end

    # Cost of the routes as they stand, in the stored (or default) order — the
    # bar a re-solve has to clear before its shuffle is worth anybody's time.
    def previous_cost
      cars.reject { |c| c.ride.meet_at_pickup }.sum do |car|
        stops = stops_of(car).sort_by { |p| [p.pickup_position || 1 << 30, p.display_name.to_s] }
        route_cost(car, stops)
      end
    end

    def proposed_cost(routes)
      routes.sum { |car, order| route_cost(car, order) }
    end

    # The detour metric the solver now prices: a real driver's outbound leg,
    # the between-pickup travel, and a stop each — never the shared haul home.
    def route_cost(car, stops)
      here = car.ride.pickup&.coords? ? @matrix.point_for(car.ride) : nil
      total = 0
      stops.each do |ride|
        there = @matrix.point_for(ride) or next
        total += @matrix.seconds(here, there) if here
        total += STOP_SECONDS
        here = there
      end
      total
    end
  end
end
