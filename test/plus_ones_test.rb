require_relative 'test_helper'

# Issue #22: people who are not in the Discord, added by the coordinator and
# linked to whoever brought them — same car, same pickup.
class PlusOnesTest < AbidTest
  def setup
    super
    @event = make_event(name: 'Abide')
    @home = Location.create!(name: 'Cary Quadrangle', zone: ZONE_1, lat: 40.4278, lon: -86.9210,
                             address: '1000 W Stadium Avenue')
  end

  def host_at(name, location = @home, driver: nil)
    ride = make_rider(@event, name, zone: location.zone, driver: driver)
    ride.update!(pickup_location: location)
    ride
  end

  def guest_of(host, name = 'Visiting Friend')
    RideDetails.create_guest(@event, host_ride_id: host.id, name: name)
  end

  # --- the row --------------------------------------------------------------

  def test_a_plus_one_is_a_ride_with_a_name_and_no_account
    guest = guest_of(host_at('anna'))

    assert guest.guest?
    assert_nil guest.user_id
    assert_equal 'Visiting Friend', guest.display_name
    assert_equal 0, User.where(name: 'Visiting Friend').count, 'invented a member for a plus-one'
  end

  def test_a_nameless_plus_one_is_refused
    host = host_at('anna')
    assert_raises(ActiveRecord::RecordInvalid) { guest_of(host, '  ') }
  end

  def test_the_host_must_be_on_the_same_event
    other = make_event(name: 'Elsewhere', starts: @event.start_time + 1.day)
    stranger = make_rider(other, 'far away')

    assert_raises(ActiveRecord::RecordInvalid) do
      @event.rides.create!(guest_name: 'x', host_ride: stranger, role: 'rider')
    end
  end

  def test_two_plus_ones_on_one_event_do_not_collide_on_the_member_uniqueness
    host = host_at('anna')
    guest_of(host, 'One')
    guest_of(host, 'Two')

    assert_equal 2, host.guests.count
  end

  # --- same pickup ----------------------------------------------------------

  def test_a_plus_one_is_picked_up_where_the_host_is
    host = host_at('anna')
    guest = guest_of(host)

    assert_equal @home, guest.pickup
    assert_equal host.zone, guest.zone
    assert_equal host.pickup_maps_query, guest.pickup_maps_query
  end

  def test_a_plus_one_can_have_a_pickup_of_their_own
    guest = guest_of(host_at('anna'))
    guest.update!(pickup_address: '120 S 3rd St')

    assert_equal '120 S 3rd St', guest.address
  end

  # --- same car -------------------------------------------------------------

  def test_a_plus_one_of_a_seated_host_is_seated_in_the_same_car
    car = make_driver(@event, 'ian', seats: 4)
    host = host_at('anna', driver: car)

    guest = guest_of(host)

    assert_equal car.id, guest.driver_ride_id
    assert_equal 'assigned', guest.status
  end

  def test_moving_the_host_moves_the_plus_one
    car_a = make_driver(@event, 'ian', seats: 4)
    car_b = make_driver(@event, 'caleb', seats: 4)
    host = host_at('anna', driver: car_a)
    guest = guest_of(host)

    host.update!(driver_ride_id: car_b.id)
    assert_equal car_b.id, guest.reload.driver_ride_id

    host.update!(driver_ride_id: nil, status: 'requested')
    assert_nil guest.reload.driver_ride_id
    assert_equal 'requested', guest.status
  end

  def test_a_host_who_is_not_coming_takes_their_plus_one_with_them
    car = make_driver(@event, 'ian', seats: 4)
    host = host_at('anna', driver: car)
    guest = guest_of(host)

    host.update!(status: 'cancelled', driver_ride_id: nil)

    assert_equal 'cancelled', guest.reload.status
    assert_nil guest.driver_ride_id
  end

  def test_a_driver_bringing_a_friend_has_them_in_their_own_car
    driver = make_driver(@event, 'ian', seats: 4)

    guest = guest_of(driver, 'Roommate')

    assert_equal driver.id, guest.driver_ride_id
    assert guest.riding_from_the_start?
  end

  def test_removing_the_host_keeps_the_plus_one_visible
    host = host_at('anna')
    guest = guest_of(host)

    host.destroy

    guest.reload
    assert_nil guest.host_ride_id, 'guest was deleted or left dangling with the host'
    refute guest.following_host?
  end

  # --- the greedy filler never splits a group or overfills a car -----------

  def test_greedy_fill_seats_the_group_together_and_counts_every_seat
    small = make_driver(@event, 'tiny car', seats: 1)
    big = make_driver(@event, 'big car', seats: 4)
    host = host_at('anna')
    guest = guest_of(host)

    seated = AutoFiller.new(@event.reload).call

    assert_equal 2, seated
    assert_equal big.id, host.reload.driver_ride_id, 'a party of two went into a one-seat car'
    assert_equal big.id, guest.reload.driver_ride_id
    assert_equal 0, Ride.where(driver_ride_id: small.id).count
  end

  # --- the driver's DM ------------------------------------------------------

  def test_the_driver_dm_says_who_a_plus_one_came_with
    car = make_driver(@event, 'ian', seats: 4)
    host = host_at('anna', driver: car)
    guest_of(host, 'Visiting Friend')
    board = RideBoard.new(@event.reload)

    dispatch = DispatchPlanner.new(board, scope: 'all').call
    body = DriverBriefing.new(dispatch.messages.first.roster).to_text

    assert_includes body, 'Visiting Friend'
    assert_includes body, '+1 of Anna'
  end

  def test_a_drivers_own_plus_one_is_not_a_pickup_but_is_mentioned
    driver = make_driver(@event, 'ian', seats: 4)
    guest_of(driver, 'Roommate')
    board = RideBoard.new(@event.reload)

    plan = RoutePlanner.new(board.cars.first, event: @event).call
    assert_empty plan.pickups, 'the driver was sent to collect someone already in the car'

    dispatch = DispatchPlanner.new(board, scope: 'all').call
    assert_includes DriverBriefing.new(dispatch.messages.first.roster).to_text,
                    'Riding with you from the start: Roommate'
  end

  # --- no false double-booking ----------------------------------------------

  def test_plus_ones_on_two_events_are_not_a_double_booking
    sibling = make_event(name: 'Dinner', starts: @event.start_time - 1.hour)
    guest_of(host_at('anna'))
    sibling_host = make_rider(sibling, 'brian')
    RideDetails.create_guest(sibling, host_ride_id: sibling_host.id, name: 'Someone Else')

    assert_empty RideBoard.new(@event.reload).elsewhere, 'two unrelated plus-ones matched on a nil user'
  end
end
