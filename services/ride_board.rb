require_relative 'auto_filler'

# Everything the ride board needs for one event occurrence, computed once.
#
# Port of the `cols()` / `renderVals()` pair in the Ride Board design: the design
# holds riders, drivers and an `assign` map in component state, whereas here the
# assignment lives in rides.driver_ride_id and the "slot" is an Event.
class RideBoard
  attr_reader :event, :query, :selected_ride_id, :focus_ride_id

  def initialize(event, query: nil, selected_ride_id: nil, focus_ride_id: nil)
    @event = event
    @query = query.to_s.strip.downcase
    @selected_ride_id = selected_ride_id&.to_i
    @focus_ride_id = focus_ride_id&.to_i
  end

  # Every ride for this occurrence, with the associations the board reads, so the
  # view never triggers a query per card.
  def rides
    @rides ||= event.rides
                    .includes(:pickup_location, user: :location)
                    .to_a
  end

  def driver_rides
    @driver_rides ||= rides.select(&:driver?).sort_by { |r| r.display_name.downcase }
  end

  def rider_rides
    @rider_rides ||= rides.select(&:rider?).sort_by { |r| r.display_name.downcase }
  end

  # Drivers actually driving today.
  def cars
    @cars ||= driver_rides.select(&:active?).map { |d| Car.new(d, passengers_for(d)) }
  end

  # Everyone who still needs a seat.
  #
  # Not simply "driver_ride_id is nil". A rider can point at a driver who is no
  # longer driving — marked out, or switched back to being a rider — and those
  # riders were in no car AND in no queue: invisible on the board, still counted
  # as seated, and silently left behind. `unrouted_riders` is the same set and
  # is what the map draws as waiting.
  def pool
    @pool ||= unrouted_riders
  end

  # Active riders who are not in any car that is actually driving.
  def unrouted_riders
    @unrouted_riders ||= begin
      driving = cars.map(&:id).to_set
      rider_rides.select { |r| r.active? && !driving.include?(r.driver_ride_id) }
    end
  end

  def out_riders
    @out_riders ||= rider_rides.select(&:out?)
  end

  # Pool filtered by the search box, grouped by zone in ZONES order. Zones with
  # nobody in them are dropped.
  #
  # Every waiting rider must appear in exactly one group. This used to build
  # `ZONES.map { [z, grouped[z]] } + [['Unzoned', grouped[nil]]]`, which silently
  # DROPPED anyone holding a zone that was not in the list — not nil, so not
  # Unzoned either. They vanished from the queue while pool_count still counted
  # them, so the footer said "7 waiting" above a queue showing four. Consuming
  # the hash with `delete` makes the partition total by construction.
  def queue_groups
    grouped = visible_pool.group_by { |r| r.zone.presence }

    known = Location::ZONES.map { |zone| [zone, grouped.delete(zone)] }
    # Whatever is left is a zone nobody recognises — a name from before a
    # rename, or free text typed into the details rail. It gets its own labelled
    # bucket rather than being folded into Unzoned: "we don't know where they
    # live" and "this zone list is stale" need different fixes.
    unknown = grouped.except(nil).sort.map { |zone, riders| ["#{zone} (unrecognised)", riders] }

    (known + unknown + [['Unzoned', grouped[nil]]]).filter_map do |zone, riders|
      next if riders.blank?
      { zone: zone, count: riders.size, riders: riders }
    end
  end

  def visible_pool
    return pool if query.empty?
    pool.select do |r|
      r.display_name.downcase.include?(query) || r.zone.to_s.downcase.include?(query)
    end
  end

  def selected
    return nil if selected_ride_id.nil?
    @selected ||= rider_rides.find { |r| r.id == selected_ride_id }
  end

  def focused
    return nil if focus_ride_id.nil?
    @focused ||= rides.find { |r| r.id == focus_ride_id }
  end

  # Memoised: the dispatch bar and every car badge read these, and both cost a
  # query.
  def readiness
    @readiness ||= DispatchReadiness.new(self)
  end

  # A sweep has been asked for and the bot has not done it yet. Scoped to the
  # service DATE because a Sunday's two services share one sign-up post.
  def sync_pending?
    return false if service_date.nil?

    SignupPost.reconcile_requested.where(service_date: service_date).exists?
  end

  def signup_posts
    @signup_posts ||= service_date ? SignupPost.where(service_date: service_date).to_a : []
  end

  # What the last sweep did, so the button can say more than nothing. nil until
  # one has run.
  #
  # A failure on ANY post for the date wins: "2 added" next to a message the bot
  # could not reach would read as success when half the roster is unverifiable.
  def last_sync
    posts = signup_posts.select { |p| p.reconciled_at.present? && p.reconcile_note.present? }
    return nil if posts.empty?

    posts.find { |p| p.reconcile_ok == false } || posts.max_by(&:reconciled_at)
  end

  def service_date
    event.occurrence_date || event.start_time&.to_date
  end

  def dispatch_status
    @dispatch_status ||= DispatchStatus.new(self)
  end

  # People on this board who also hold an active ride on ANOTHER event the
  # same day — riding or driving. {user_id => ["driving Abide dinner — 5:30 PM"]}
  #
  # Same DAY, not a 45-minute overlap window. The old readiness check used 45
  # minutes, and the services are 60 apart — so signing up for both Friday
  # times, the actual mistake people make, never fired it. Someone riding to
  # the 5:30 is already at the church for the 6:30; a second pickup for them is
  # a seat wasted and a driver told to collect somebody who is not there.
  def elsewhere
    @elsewhere ||= begin
      # compact: plus-ones have no user, and a nil here would match every other
      # plus-one on the day.
      ids = rides.select(&:active?).filter_map(&:user_id)
      if ids.empty? || service_date.nil?
        {}
      else
        Ride.active
            .joins(:event)
            .where(user_id: ids)
            .where.not(event_id: event.id)
            .where(events: { disabled: false, start_time: service_date.all_day })
            .includes(:event)
            .group_by(&:user_id)
            .transform_values do |others|
              others.map { |r| "#{r.driver? ? 'driving' : 'also on'} #{r.event.display_name}" }
            end
      end
    end
  end

  def elsewhere_for(ride)
    return nil if ride.user_id.nil?

    elsewhere[ride.user_id]
  end

  # --- counters shown in the header and footer -----------------------------

  def pool_count
    pool.size
  end

  # Seated in a car that is going, which is the only kind of seated that helps
  # anyone. Counting a rider attached to a withdrawn driver made the header read
  # "3 seated" for three people nobody was collecting.
  def seated_count
    cars.sum { |car| car.passengers.size }
  end

  def seats_left
    cars.sum(&:seats_free)
  end

  def overfull_count
    cars.count(&:over?)
  end

  def warnings
    [].tap do |warn|
      warn << "#{pool_count} still without a ride" if pool_count.positive?
      warn << "#{overfull_count} #{'car'.pluralize(overfull_count)} over capacity" if overfull_count.positive?
    end
  end

  def warning_text
    warnings.join(' · ')
  end

  # --- sibling occurrences, rendered as the slot tabs ------------------------

  def date
    @date ||= (event.start_time || Time.zone.now).to_date
  end

  def sibling_events
    @sibling_events ||= Event.active
                             .where(start_time: date.all_day)
                             .chronological
                             .to_a
  end

  # The tag this occurrence draws its drivers from — "Friday-Usual" on a Friday
  # board. Set on the series and copied down; nil on a one-off nobody has said
  # anything about.
  def driver_tag
    event.driver_tag_for_board
  end

  # Who "add the regular drivers" would put on this board.
  #
  # Scoped to the tag when there is one. Without it this was every active member
  # with a seat count — the same list on a Friday as on a Sunday, which is not
  # the same list in real life, so the button added people who were not coming.
  #
  # Untagged falls back to all of them rather than to nobody: a board whose
  # series has no tag yet should keep working exactly as it did.
  def regular_drivers
    @regular_drivers ||= driver_tag ? drivers_tagged(driver_tag) : addable_drivers
  end

  def regular_driver_count
    @regular_driver_count ||= regular_drivers.count
  end

  # How many drivers there would be if the tag were ignored. Lets the board tell
  # "nobody carries this tag yet" apart from "everyone is already on the board",
  # which look identical from a count of zero and need opposite responses.
  def untagged_driver_count
    @untagged_driver_count ||= addable_drivers.count
  end

  # Everyone who could be added to this board, whatever their tags.
  def addable_drivers
    @addable_drivers ||= User.active.drivers.where.not(id: rides.map(&:user_id)).to_a
  end

  # Every tag with how many people it would add HERE — not how many carry it.
  #
  # The distinction matters once half a car list is already on the board: a tag
  # of six that would add one is the honest number, and the other reading turns
  # the button into a lie the second time you press it.
  #
  # This day's own tag first, then the rest, so the common case is the leftmost
  # button without hiding the others — which is the point: a one-off, a retreat,
  # or a Friday where the Sunday people are covering is a real Tuesday problem.
  def driver_tag_options
    @driver_tag_options ||= begin
      counts = User.known_tags.to_h do |tag|
        [tag, addable_drivers.count { |d| d.tagged?(tag) }]
      end

      ordered = counts.keys.sort_by { |tag| [tag.casecmp?(driver_tag.to_s) ? 0 : 1, tag.downcase] }
      ordered.map { |tag| { tag: tag, count: counts[tag], preferred: tag.casecmp?(driver_tag.to_s) } }
    end
  end

  def drivers_tagged(tag)
    addable_drivers.select { |d| d.tagged?(tag) }
  end

  # --- stepping to the occurrence either side --------------------------------
  #
  # Relative to the event on screen, NOT to `Time.zone.now`. `Event.upcoming` is
  # keyed off now, so it answers the wrong question the moment you are looking
  # at a board from last Sunday.

  def next_event
    return @next_event if defined?(@next_event)

    @next_event = neighbour('start_time > ?', :asc)
  end

  def previous_event
    return @previous_event if defined?(@previous_event)

    @previous_event = neighbour('start_time < ?', :desc)
  end


  # One car column: the driver's ride plus who's in it.
  class Car
    attr_reader :ride, :passengers

    def initialize(ride, passengers)
      @ride = ride
      @passengers = passengers
    end

    def id = ride.id
    def name = ride.display_name
    def zone = ride.zone
    def seats = ride.capacity
    def used = passengers.size
    def empty? = passengers.empty?
    def over? = used > seats
    def full? = used >= seats
    def seats_free = [seats - used, 0].max
    def seat_text = "#{used} of #{seats} seats"

    def fill_percent
      return 0 if seats.zero?
      [(used.to_f / seats * 100).round, 100].min
    end

    # The pill shown on each car while a rider is selected.
    def fit_for(rider)
      return nil if rider.nil?
      return :full if full?
      return :closest if zone.present? && zone == rider.zone
      :space
    end
  end

  private

  def passengers_for(driver_ride)
    rider_rides.select { |r| r.driver_ride_id == driver_ride.id && r.active? }
  end

  def neighbour(condition, direction)
    # An event created through the Discord modal can have no start_time, and
    # there is no sensible "the one after this" from a point that is not on the
    # timeline at all.
    return nil if event.start_time.nil?

    Event.active
         .where(condition, event.start_time)
         .order(start_time: direction)
         .first
  end
end
