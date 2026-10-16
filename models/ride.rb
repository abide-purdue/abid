class Ride < ApplicationRecord
  ROLES = %w[rider driver].freeze
  STATUSES = %w[requested assigned confirmed cancelled no_show].freeze

  # Who created this row. Reaction handling only ever touches 'discord' rides,
  # so a rider a coordinator added by hand cannot be removed by Discord traffic.
  SOURCES = %w[manual discord].freeze

  # Statuses that take someone off the board for the day. The design calls this
  # "not coming" for riders and "not driving today" for drivers.
  OUT_STATUSES = %w[cancelled no_show].freeze

  belongs_to :event
  # Optional for plus-ones (issue #22): people who are not in the Discord,
  # known only by the name the coordinator typed.
  belongs_to :user, optional: true
  belongs_to :pickup_location, class_name: 'Location', optional: true

  # Whoever brought this plus-one. Same car, same pickup: the guest follows the
  # host wherever the host is seated (see carry_guests), and has no pickup of
  # their own unless one is typed in.
  belongs_to :host_ride, class_name: 'Ride', optional: true
  has_many :guests, class_name: 'Ride', foreign_key: :host_ride_id

  # A rider points at the driver's ride row for this same event, so a driver's
  # passenger list is scoped to one occurrence instead of being a permanent
  # property of the user (which is what users.driver_id implied).
  belongs_to :driver_ride, class_name: 'Ride', optional: true
  # Deliberately NOT `dependent: :nullify`. That option registers its own
  # before_destroy when the association is declared, so it ran first and cleared
  # driver_ride_id before anything else could look at the passengers — leaving
  # `unseat_passengers` with an empty set and riders still marked 'assigned'.
  # Doing both here, in order, is the only way they stay consistent.
  has_many :passengers, class_name: 'Ride', foreign_key: :driver_ride_id

  has_many :signup_reactions, dependent: :nullify

  before_validation :canonicalize_zone
  # A pickup order belongs to the route it was computed for. Move a rider to
  # another car by hand and their old position came along — position 0 from the
  # previous route, silently jumping the new car's DM order. The optimizer is
  # unaffected: it writes driver_ride_id and pickup_position in one update, so
  # the position is changed too and survives.
  before_save :drop_stale_pickup_position, if: lambda {
    driver_ride_id_changed? && !pickup_position_changed?
  }
  # Deleting a driver puts their riders back in the waiting queue, rather than
  # taking them off the board along with the car. Somebody who dropped out of
  # driving has not told us anything about whether their passengers still need
  # a lift — they do, and they are now the most urgent people on the board.
  before_destroy :unseat_passengers
  # Seat changes and comings-and-goings of a host carry their plus-ones along.
  after_update :carry_guests, if: lambda {
    saved_change_to_driver_ride_id? || saved_change_to_pickup_position? || saved_change_to_status?
  }

  validates :role, inclusion: { in: ROLES }
  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }
  # Same gate as Location: rides.zone wins over the location's zone, so a bad
  # value here overrides good data — but an unconditional validation would let
  # one legacy row roll back a whole AutoFiller transaction.
  validates :zone, inclusion: { in: Location::ZONES }, allow_blank: true, if: :zone_changed?
  validates :user_id, uniqueness: { scope: :event_id }, allow_nil: true
  validates :guest_name, presence: true, if: -> { user_id.nil? }
  validate :host_must_be_a_rider_on_this_event, if: :host_ride_id_changed?
  validate :driver_ride_must_be_a_driver
  validate :driver_ride_must_be_same_event

  scope :riders, -> { where(role: 'rider') }
  scope :drivers, -> { where(role: 'driver') }
  scope :active, -> { where.not(status: OUT_STATUSES) }
  scope :out, -> { where(status: OUT_STATUSES) }
  scope :assigned, -> { where.not(driver_ride_id: nil) }
  scope :unassigned, -> { riders.active.where(driver_ride_id: nil) }
  scope :in_zone, ->(zone) { where(zone: zone) }
  scope :from_discord, -> { where(source: 'discord') }
  scope :dropped, -> { where.not(dropped_at: nil) }
  scope :guests, -> { where(user_id: nil) }
  scope :members, -> { where.not(user_id: nil) }

  def rider?
    role == 'rider'
  end

  def driver?
    role == 'driver'
  end

  # Falls back to the user's default car capacity; `seats` overrides it for the
  # occasions where someone brings a different car or arrives part-full.
  def capacity
    seats || user&.capacity || 0
  end

  def seats_taken
    passengers.active.count
  end

  def seats_available
    [capacity - seats_taken, 0].max
  end

  def full?
    driver? && seats_available.zero?
  end

  # A per-occurrence override always wins; otherwise the event decides which of
  # the person's two addresses to use, falling back to home when they never
  # told us where their Friday class is.
  def pickup
    pickup_location || (guest? ? host_ride&.pickup : user_pickup)
  end

  # Someone who is not in the Discord: no account, no DMs, no reactions.
  def guest?
    user_id.nil?
  end

  # A plus-one riding along with their host rather than placed on their own.
  # An unlinked guest (host gone) is seated like anyone else.
  def following_host?
    guest? && host_ride.present? && host_ride.active?
  end

  def user_pickup
    return nil if user.nil?
    return user.location if event&.pickup_source != 'class'

    user.class_location || user.location
  end

  def coords
    pickup&.coords
  end

  # Per-occurrence override wins, then the pickup location's zone.
  def zone
    self[:zone].presence || pickup&.zone
  end

  def zone_short
    Location.zone_short(zone)
  end

  # What the details rail shows in the address field: the free text the
  # coordinator typed, falling back to whatever location we have on file.
  def address
    pickup_address.presence || (guest? ? host_ride&.address : nil) || pickup&.name
  end

  # What to put in the driver's Google Maps link for this pickup.
  #
  # Typed text first — it is a correction to where the pin sits ("north door",
  # "apt 412"), and it is the more specific of the two. Then the location's own
  # street address. nil when we have neither, and the route falls back to the
  # coordinates.
  #
  # The typed text is passed through with the city appended only when it does
  # not already name one, so "123 Vine St, Lafayette" is not turned into
  # "123 Vine St, Lafayette, West Lafayette, Indiana".
  def pickup_maps_query
    return host_ride&.pickup_maps_query if pickup_address.blank? && guest? && pickup_location.nil?
    return pickup&.maps_query if pickup_address.blank?

    typed = pickup_address.strip
    return typed if typed.match?(/lafayette/i)

    [typed, pickup&.city || 'West Lafayette, Indiana'].join(', ')
  end

  def out?
    OUT_STATUSES.include?(status)
  end

  def from_discord?
    source == 'discord'
  end

  # Un-reacted after a coordinator had already seated them. The seat is freed
  # but the row stays on the board rather than silently vanishing.
  def dropped?
    dropped_at.present?
  end

  def active?
    !out?
  end

  def display_name
    return guest_name.to_s if guest?

    user&.display_name.to_s
  end

  def to_s
    "#{user&.name || 'unknown'} (#{role}, #{status})"
  end

  # Where this ride's plus-ones sit: in the host's car — or, when the host is
  # a driver bringing a friend, in the host's own car.
  def guest_seat
    driver? ? id : driver_ride_id
  end

  # Riding with the driver from the moment the car leaves — not a pickup.
  def riding_from_the_start?
    following_host? && host_ride.driver?
  end

  private

  def drop_stale_pickup_position
    self.pickup_position = nil
  end

  # update_all: the guests' own callbacks must not re-fire (they have no
  # guests), and a seat move should be one statement however many came along.
  # A host going out takes their plus-ones out too — they came together; a
  # host coming back brings them back with them.
  def carry_guests
    return if guests.empty?

    seat = guest_seat
    attrs = { driver_ride_id: seat, updated_at: Time.current,
              # Same stop as the host; none at all when they ride from the start.
              pickup_position: driver? ? nil : pickup_position }
    attrs[:status] = if out? then status
                     elsif seat then 'assigned'
                     else 'requested'
                     end
    guests.update_all(attrs)
  end

  def host_must_be_a_rider_on_this_event
    return if host_ride.nil?

    errors.add(:host_ride, 'must be on the same event') unless host_ride.event_id == event_id
    errors.add(:host_ride, 'is not coming') if host_ride.out?
    errors.add(:host_ride, 'cannot itself be a plus-one') if host_ride.guest?
    errors.add(:host_ride, 'cannot be themselves') if host_ride_id == id
  end

  # Status first, while the riders are still linked to this car; then the link.
  #
  # Only 'assigned' is reset: that status means "seated in a car", and the car
  # is going. A rider who had confirmed or cancelled said something about
  # themselves, not about this driver, and that survives.
  def unseat_passengers
    passengers.where(status: 'assigned').update_all(status: 'requested', updated_at: Time.current)
    passengers.update_all(driver_ride_id: nil, updated_at: Time.current)
  end

  # `self[:zone]`, never `self.zone` — the reader below is overridden to fall
  # through to the pickup location, so `self.zone = zone` would copy the
  # location's zone onto the ride and destroy the "no override" state.
  def canonicalize_zone
    self[:zone] = Location.canonical_zone(self[:zone])
  end

  def driver_ride_must_be_a_driver
    return if driver_ride.nil?
    errors.add(:driver_ride, 'must be a driver') unless driver_ride.driver?
  end

  def driver_ride_must_be_same_event
    return if driver_ride.nil?
    errors.add(:driver_ride, 'must be for the same event') unless driver_ride.event_id == event_id
  end
end
