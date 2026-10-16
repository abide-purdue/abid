require_relative '../map/map'

# Writes from the details rail and the "add someone" form.
#
# Fields are split across two tables on purpose: a phone number and a name are
# facts about the person and should persist between weeks, whereas the pickup
# spot, seat count and notes are per-occurrence.
class RideDetails
  USER_FIELDS = %w[name phone].freeze
  # `role` is here so a rider can be promoted to driver in place. Without it the
  # only way to say "actually Caleb is driving" was to delete his ride and add
  # him again — and since everyone who reacts to a sign-up arrives as a rider,
  # that was every driver, every week.
  RIDE_FIELDS = %w[role zone pickup_address note seats].freeze
  # Checkbox param handled separately: absent must not mean false on forms
  # that do not render it (rider rails).

  def initialize(ride)
    @ride = ride
  end

  def apply(params)
    Ride.transaction do
      update_user(params)
      update_ride(params)
      if params.key?(:meet_at_pickup) && @ride.driver?
        @ride.update!(meet_at_pickup: params[:meet_at_pickup] == '1')
      end
      seat_a_new_driver
      geocode_pickup
    end
    @ride
  end

  def self.create_for(event, params)
    user = User.find(params[:user_id])
    role = Ride::ROLES.include?(params[:role].to_s) ? params[:role].to_s : 'rider'

    event.rides.create!(
      user: user,
      role: role,
      status: 'requested',
      zone: params[:zone].presence || user.location&.zone,
      seats: role == 'driver' ? (user.capacity.presence || 4) : nil,
      signed_up_at: Time.zone.now
    )
  end

  # A plus-one (issue #22): someone not in the Discord, riding with whoever
  # brought them. Seated straight into the host's car if the host already has
  # one — or into the host's own car when the host is driving.
  def self.create_guest(event, host_ride_id:, name:)
    host = event.rides.find(host_ride_id)
    guest = event.rides.create!(
      guest_name: name.to_s.strip, host_ride: host, role: 'rider',
      status: 'requested', source: 'manual', signed_up_at: Time.zone.now
    )
    seat = host.guest_seat
    guest.update!(driver_ride_id: seat, status: 'assigned') if seat && host.active?
    guest
  end

  private

  def update_user(params)
    # A plus-one's name lives on the ride; there is no user to update.
    if @ride.guest?
      @ride.update!(guest_name: params['name'].strip) if params['name'].present?
      return
    end

    user = @ride.user
    return if user.nil?

    attrs = {}
    # A blank name would wipe the Discord-synced display name, so ignore it.
    attrs[:name] = params['name'] if params['name'].present?
    # A blank phone, on the other hand, is a deliberate clear.
    attrs[:phone] = params['phone'].presence if params.key?('phone')

    user.update!(attrs) if attrs.any?
  end

  def update_ride(params)
    attrs = params.slice(*RIDE_FIELDS)
    if @ride.guest?
      attrs.delete('role') # a plus-one has no seats to drive
      attrs.delete('seats')
    end
    attrs['seats'] = normalize_seats(attrs['seats']) if attrs.key?('seats')
    attrs['zone'] = attrs['zone'].presence if attrs.key?('zone')
    # Dropped rather than passed through: `update!` raises on an invalid role,
    # which would turn a stray param into a 500 on the board.
    attrs.delete('role') unless Ride::ROLES.include?(attrs['role'])
    @ride.update!(attrs)
  end

  def normalize_seats(value)
    return nil if value.blank?
    [[value.to_i, 1].max, 20].min
  end

  # Best-effort: turn the typed address into a real Location so the route
  # suggestion in map.rb has coordinates to work with. Never blocks the save —
  # OSM is a third party and the board has to stay usable on a Sunday morning.
  def geocode_pickup
    address = @ride.pickup_address
    return if address.blank?
    return if @ride.pickup_location&.name == address

    existing = Location.search_by_name(address).first
    location = existing || safely { Map.new.create_new_location(address) }
    return if location.nil?

    location.update(zone: @ride.zone) if location.zone.blank? && @ride.zone.present?
    @ride.update_column(:pickup_location_id, location.id)

    # And remember it as where they live, if we did not already know. This was
    # written only onto the ride, so the same person triggered the blocking
    # "no pickup" finding again next week and the same address got typed again.
    user = @ride.user
    user.update(location_id: location.id) if user && user.location_id.blank?
  end

  # A promoted driver with no seats would show a car with nowhere to sit.
  def seat_a_new_driver
    return unless @ride.role == 'driver' && @ride.seats.to_i.zero?

    @ride.update(seats: @ride.user&.capacity.presence || 4)
  end

  def safely
    yield
  rescue StandardError => e
    warn "geocoding failed for ride #{@ride.id}: #{e.class}: #{e.message}"
    nil
  end
end
