require_relative 'test_helper'

# The two promises the optimizer makes are worth more than its optimality:
# seated riders never change cars, and the pool is droppable rather than the
# solve being fragile. Optimality is asserted only loosely (the obviously
# cheaper car wins) because the exact objective is the solver's business.
#
# Every test injects a fake matrix, so no HTTP and no dependence on real
# geography — distances here are whatever the test says they are.
class RidesOptimizerTest < AbidTest
  # Seconds come from a hash keyed on location ids; unknown pairs are far.
  class FakeMatrix < Rides::TravelMatrix
    def initialize(times)
      super(api_key: nil)
      @times = times
    end

    def warm(_points); end

    def seconds(a, b)
      return 0 if a.nil? || b.nil? || a.location_id == b.location_id

      @times.fetch([a.location_id, b.location_id], 9_999)
    end
  end

  def setup
    super
    @venue = Location.create!(name: 'venue', zone: ZONE_1, lat: 40.45, lon: -86.97)
    @near = Location.create!(name: 'near', zone: ZONE_1, lat: 40.43, lon: -86.91)
    @far = Location.create!(name: 'far', zone: ZONE_2, lat: 40.42, lon: -86.90)
    @event = make_event(name: 'Sunday Service')
    @event.update!(location: @venue)
  end

  def driver_at(name, location, seats: 4)
    ride = make_driver(@event, name, seats: seats, zone: location.zone)
    ride.update!(pickup_location: location)
    ride
  end

  def rider_at(name, location, driver: nil)
    ride = make_rider(@event, name, zone: location.zone, driver: driver)
    ride.update!(pickup_location: location)
    ride
  end

  def optimize(times)
    Rides::Optimizer.call(RideBoard.new(@event.reload), matrix: FakeMatrix.new(times))
  end

  # Symmetric convenience: same time both directions unless overridden.
  def matrix(pairs)
    pairs.flat_map { |(a, b), s| [[[a.id, b.id], s], [[b.id, a.id], s]] }.to_h
  end

  def test_seats_the_pool_into_the_cheaper_car
    near_driver = driver_at('ian', @near)
    far_driver = driver_at('caleb', @far)
    rider = rider_at('caitlin', @near)

    result = optimize(matrix(
      [@near, @venue] => 600, [@far, @venue] => 700,
      [@near, @far] => 1200, [@near, @near] => 0
    ))

    assert_equal :or_tools, result.engine
    assert_equal 1, result.seated
    assert_equal near_driver.id, rider.reload.driver_ride_id,
                 'the rider at the near driver\'s own stop went to the far car'
    refute_equal far_driver.id, rider.reload.driver_ride_id
  end

  # The core promise: a seated rider stays put even when moving them is
  # obviously cheaper. Construct the temptation explicitly.
  def test_a_seated_rider_never_changes_cars
    expensive = driver_at('ian', @far)
    driver_at('caleb', @near)
    stuck = rider_at('caitlin', @near, driver: expensive)

    optimize(matrix(
      [@near, @venue] => 60, [@far, @venue] => 60, [@near, @far] => 3600
    ))

    assert_equal expensive.id, stuck.reload.driver_ride_id,
                 'the optimizer moved a seated rider to save time — forbidden'
  end

  def test_a_late_rider_joins_without_disturbing_anyone
    car_a = driver_at('ian', @near, seats: 2)
    car_b = driver_at('caleb', @far, seats: 2)
    veteran_a = rider_at('anna', @near, driver: car_a)
    veteran_b = rider_at('brian', @far, driver: car_b)
    late = rider_at('priya', @near)

    result = optimize(matrix(
      [@near, @venue] => 300, [@far, @venue] => 300, [@near, @far] => 2000
    ))

    assert_equal 1, result.seated
    assert_equal car_a.id, late.reload.driver_ride_id, 'joined the wrong car'
    assert_equal car_a.id, veteran_a.reload.driver_ride_id
    assert_equal car_b.id, veteran_b.reload.driver_ride_id
  end

  def test_capacity_is_respected_and_overflow_stays_in_the_pool
    driver_at('ian', @near, seats: 1)
    riders = 3.times.map { |i| rider_at("r#{i}", @near) }

    result = optimize(matrix([@near, @venue] => 300))

    seated = riders.count { |r| r.reload.driver_ride_id.present? }
    assert_equal 1, seated, 'a one-seat car took more than one rider'
    assert_equal 2, result.dropped
    assert_equal 2, RideBoard.new(@event.reload).pool.size, 'overflow vanished instead of staying visible'
  end

  # Pressing the button twice must not shuffle anything: no new riders and no
  # real improvement means no writes.
  def test_running_twice_is_a_noop
    driver_at('ian', @near, seats: 4)
    rider_at('caitlin', @near)
    times = matrix([@near, @venue] => 300)

    optimize(times)
    stamps = @event.reload.rides.order(:id).pluck(:updated_at, :pickup_position, :driver_ride_id)

    result = optimize(times)

    assert_equal 0, result.seated
    assert_equal 0, result.reordered
    assert_equal stamps, @event.reload.rides.order(:id).pluck(:updated_at, :pickup_position, :driver_ride_id),
                 'a no-op run still wrote to rides'
  end

  # A rider whose location has no coordinates still has a zone, and the zone's
  # centroid keeps them optimizable rather than invisible.
  def test_a_coordless_rider_is_still_seated
    driver_at('ian', @near, seats: 4)
    homeless = make_rider(@event, 'mystery', zone: ZONE_1)
    refute homeless.pickup&.coords?, 'fixture drift: this rider was supposed to be unlocatable'

    result = Rides::Optimizer.call(RideBoard.new(@event.reload))

    assert_operator result.seated, :>=, 1
    refute_nil homeless.reload.driver_ride_id, 'a coordless rider was left invisible in the pool'
  end

  # No venue coordinates → the solver cannot run → the greedy filler answers.
  # The button must degrade, never 500.
  def test_falls_back_to_greedy_when_the_venue_is_unlocatable
    @venue.update_columns(lat: nil, lon: nil)
    driver_at('ian', @near, seats: 4)
    rider = rider_at('caitlin', @near)

    result = capture_io { @r = optimize(matrix({})) }.then { @r }

    assert_equal :greedy, result.engine
    refute_nil rider.reload.driver_ride_id, 'the fallback did not seat anyone either'
  end

  # Inserting into a sent car flips exactly that driver to changed — the
  # digest is a set, so the untouched car stays sent.
  def test_late_insert_flips_only_the_affected_driver
    car_a = driver_at('ian', @near, seats: 3)
    car_b = driver_at('caleb', @far, seats: 3)
    rider_at('anna', @near, driver: car_a)
    rider_at('brian', @far, driver: car_b)

    board = RideBoard.new(@event.reload)
    dispatch = DispatchPlanner.new(board, scope: 'all').call
    dispatch.messages.update_all(status: 'sent', sent_at: Time.zone.now)

    rider_at('priya', @near)
    optimize(matrix(
      [@near, @venue] => 300, [@far, @venue] => 300, [@near, @far] => 2000
    ))

    status = DispatchStatus.new(RideBoard.new(@event.reload))
    assert_equal :changed, status.state_for(car_a), 'the driver gaining a rider must be re-sendable'
    assert_equal :sent, status.state_for(car_b), 'an untouched car was re-flagged'
  end
  # The stale-position guard must not eat the optimizer's own writes: it sets
  # driver_ride_id and pickup_position in one update, and both must land.
  def test_the_optimizer_keeps_its_own_pickup_positions
    driver_at('ian', @near, seats: 4)
    a = rider_at('anna', @near)
    b = rider_at('brian', @far)

    optimize(matrix(
      [@near, @venue] => 300, [@far, @venue] => 600, [@near, @far] => 200
    ))

    positions = [a, b].map { |r| r.reload.pickup_position }
    assert_equal [0, 1], positions.sort, "the guard wiped the optimizer's order: #{positions.inspect}"
  end

  # The failure the user actually saw: total-time alone always prefers one car
  # snaking through every pickup, because each car's own drive to the venue is
  # paid regardless. The route cap plus per-stop time must spread the load.
  def test_riders_are_distributed_rather_than_snaked_into_one_car
    driver_at('ian', @near, seats: 12)
    driver_at('caleb', @near, seats: 12)
    spots = 8.times.map do |i|
      Location.create!(name: "stop #{i}", zone: ZONE_1, lat: 40.43 + (i * 0.004), lon: -86.91)
    end
    riders = spots.each_with_index.map { |spot, i| rider_at("r#{i}", spot) }

    # Legs long enough that eight stops on one route blow the 30-minute cap,
    # but four on each fit comfortably.
    times = {}
    all = spots + [@near, @venue]
    all.each do |a|
      all.each { |b| times[[a.id, b.id]] = a == b ? 0 : 240 }
    end

    result = optimize(times)

    assert_equal 8, result.seated
    loads = [riders.count { |r| r.reload.driver_ride_id }].then do
      @event.reload.rides.drivers.map { |d| Ride.where(driver_ride_id: d.id).count }.sort
    end
    assert_operator loads.min, :>=, 2, "one car took nearly everything: #{loads.inspect}"
  end

  # A board optimized under the old objective sits in a snake the new cap
  # forbids. The idempotence guard must not protect it.
  def test_a_snake_from_the_old_objective_is_broken_up_on_repress
    fast = driver_at('ian', @near, seats: 12)
    driver_at('caleb', @near, seats: 12)
    spots = 8.times.map { |i| Location.create!(name: "s#{i}", zone: ZONE_1, lat: 40.4 + (i * 0.004), lon: -86.9) }
    riders = spots.each_with_index.map { |spot, i| rider_at("r#{i}", spot) }
    # Everyone crammed into one car with stored positions, old-style.
    riders.each_with_index { |r, i| r.update!(driver_ride_id: fast.id, status: 'assigned', pickup_position: i) }

    times = {}
    all = spots + [@near, @venue]
    all.each { |a| all.each { |b| times[[a.id, b.id]] = a == b ? 0 : 240 } }

    optimize(times)

    loads = @event.reload.rides.drivers.map { |d| Ride.where(driver_ride_id: d.id).count }.sort
    assert_operator loads.max, :<, 8, "the guard preserved the snake: #{loads.inspect}"
  end

  # --- meeting-point vehicles (the church van) ------------------------------

  def test_the_van_fills_first_with_walkable_riders_and_drives_no_route
    windsor = Location.create!(name: 'windsor lot', zone: ZONE_1, lat: 40.4260, lon: -86.9209)
    nearby = Location.create!(name: 'next door', zone: ZONE_1, lat: 40.4262, lon: -86.9200)
    van = driver_at('tyler', windsor, seats: 2)
    van.update!(meet_at_pickup: true)
    car = driver_at('ian', @near, seats: 4)

    # Deliberately different distances: nearest-first must be deterministic,
    # and three people at one point would make "which two walk" a coin toss.
    slightly_farther = Location.create!(name: 'two blocks', zone: ZONE_1, lat: 40.4290, lon: -86.9180)
    close_a = rider_at('walk a', nearby)
    close_b = rider_at('walk b', nearby)
    third = rider_at('third wheel', slightly_farther)

    result = optimize(matrix(
      [@near, @venue] => 300, [windsor, @venue] => 300, [nearby, @venue] => 300,
      [@near, windsor] => 300, [@near, nearby] => 300, [windsor, nearby] => 60,
      [slightly_farther, @venue] => 300, [@near, slightly_farther] => 200,
      [windsor, slightly_farther] => 120, [nearby, slightly_farther] => 90
    ))

    assert_equal 3, result.seated
    # Two walked to the van (nearest fill up to its seats), the overflow drove.
    assert_equal van.id, close_a.reload.driver_ride_id
    assert_equal van.id, close_b.reload.driver_ride_id
    assert_equal car.id, third.reload.driver_ride_id, 'van overflow was not handed to a driving car'
  end

  def test_someone_beyond_walking_range_is_never_sent_to_the_van
    windsor = Location.create!(name: 'windsor lot', zone: ZONE_1, lat: 40.4260, lon: -86.9209)
    van = driver_at('tyler', windsor, seats: 12)
    van.update!(meet_at_pickup: true)
    car = driver_at('ian', @far, seats: 4)
    distant = rider_at('far away', @far) # ~5km from windsor

    optimize(matrix(
      [@far, @venue] => 300, [windsor, @venue] => 300, [@far, windsor] => 600
    ))

    assert_equal car.id, distant.reload.driver_ride_id,
                 'someone 5km away was told to walk to the van'
  end

  def test_the_vans_dm_route_is_one_stop
    windsor = Location.create!(name: 'windsor lot', zone: ZONE_1, lat: 40.4260, lon: -86.9209)
    van = driver_at('tyler', windsor, seats: 4)
    van.update!(meet_at_pickup: true)
    a = rider_at('walk a', @near, driver: van)
    rider_at('walk b', @near, driver: van)

    plan = RoutePlanner.new(RideBoard.new(@event.reload).cars.first, event: @event).call

    assert_equal 2, plan.pickups.size, 'every rider still listed for the driver'
    assert plan.pickups.all? { |stop| stop.label.include?('meets at') }
    # One waypoint after dedup: the meeting spot itself.
    assert_equal 1, plan.stops[0..-2].map(&:maps_token).uniq.size
  end

  # A rider whose pickup has no coordinates falls to the zone centroid, which
  # can sit close to a meeting point by accident. Walking is a hard constraint,
  # so an unknown location must never be assigned to walk — this is the "why is
  # someone from the Mechanical Engineering Building on the van" bug.
  def test_a_coordless_rider_is_never_told_to_walk_to_the_van
    windsor = Location.create!(name: 'windsor lot', zone: ZONE_1, lat: 40.4260, lon: -86.9209)
    van = driver_at('tyler', windsor, seats: 12)
    van.update!(meet_at_pickup: true)
    car = driver_at('ian', @near, seats: 4)

    # No pickup_location and no personal location -> centroid fallback only.
    unknown = make_rider(@event, 'mystery', zone: ZONE_1)
    refute unknown.pickup&.coords?, 'fixture drift: this rider was meant to be unlocatable'

    Rides::Optimizer.call(RideBoard.new(@event.reload))

    refute_equal van.id, unknown.reload.driver_ride_id,
                 'someone whose location we do not know was sent to walk to the van'
  end

  # The bug the user caught: riders left in the pool with empty seats going
  # begging. Root cause was the objective counting the shared drive to the
  # venue, so a hard route cap (which included that drive) refused riders even
  # with capacity to spare. Everyone locatable must now be seated.
  def test_nobody_locatable_is_left_waiting_when_seats_exist
    # A venue that is FAR, like the real church — the case that broke the cap.
    far_venue = Location.create!(name: 'far church', zone: ZONE_1, lat: 40.50, lon: -87.05)
    @event.update!(location: far_venue)

    # Drivers with no pickup location: modelled at the venue, they used to be
    # unable to collect anyone without blowing the route cap.
    3.times { |i| make_driver(@event, "driver #{i}", seats: 4) }
    riders = 8.times.map { |i| rider_at("rider #{i}", @near) }

    result = Rides::Optimizer.call(RideBoard.new(@event.reload))

    assert_equal :or_tools, result.engine
    assert_equal 0, RideBoard.new(@event.reload).pool.size,
                 'riders left waiting with a far venue and empty seats — the reported bug'
    riders.each { |r| refute_nil r.reload.driver_ride_id }
  end


  # --- plus-ones (issue #22) ----------------------------------------------------
  #
  # A host and their plus-ones are one stop needing several seats: never split
  # across cars, never squeezed into a car without room for all of them.

  def test_a_host_and_plus_one_ride_together_and_need_two_seats
    one_seat = driver_at('tiny', @near, seats: 1)
    roomy = driver_at('roomy', @far, seats: 4)
    host = rider_at('anna', @near)
    guest = RideDetails.create_guest(@event, host_ride_id: host.id, name: 'Visiting Friend')

    result = optimize(matrix(
      [@near, @venue] => 300, [@far, @venue] => 300, [@near, @far] => 600
    ))

    assert_equal 2, result.seated
    assert_equal roomy.id, host.reload.driver_ride_id, 'a party of two went into a one-seat car'
    assert_equal roomy.id, guest.reload.driver_ride_id, 'the plus-one was split from the host'
    assert_equal 0, Ride.where(driver_ride_id: one_seat.id).count
  end

  def test_a_drivers_own_plus_one_takes_a_seat_before_routing
    driver = driver_at('ian', @near, seats: 2)
    RideDetails.create_guest(@event, host_ride_id: driver.id, name: 'Roommate')
    riders = 2.times.map { |i| rider_at("r#{i}", @near) }

    optimize(matrix([@near, @venue] => 300))

    seated = riders.count { |r| r.reload.driver_ride_id == driver.id }
    assert_equal 1, seated, 'filled the seat the roommate is already sitting in'
  end

end
