# Pre-flight for sending assignments to drivers.
#
# Reuses the counters RideBoard already computes, re-expressed as structured
# findings with ride ids so the UI can point at the offending cards, plus three
# checks the board does not make.
class DispatchReadiness
  Finding = Struct.new(:key, :severity, :message, :ride_ids, keyword_init: true)

  def initialize(board)
    @board = board
  end

  def findings
    @findings ||= [
      unseated_riders,
      over_capacity,
      drivers_out_with_passengers,
      riders_without_a_pickup,
      no_drivers,
      double_booked
    ].compact
  end

  # Errors block the send; warnings do not.
  def blocking
    findings.select { |f| f.severity == :error }
  end

  def advisory
    findings.select { |f| f.severity == :warn }
  end

  def ready?
    blocking.empty?
  end

  def summary
    return 'Ready to send' if findings.empty?
    return advisory.first.message if ready?

    blocking.first.message
  end

  # Compact form for the dispatch snapshot.
  def to_keys
    findings.map { |f| "#{f.key}:#{f.ride_ids.join(',')}" }
  end

  private

  # --- straight from RideBoard --------------------------------------------

  def unseated_riders
    return if @board.pool_count.zero?

    Finding.new(key: :unseated, severity: :warn,
                message: "#{@board.pool_count} still without a ride",
                ride_ids: @board.pool.map(&:id))
  end

  def over_capacity
    over = @board.cars.select(&:over?)
    return if over.empty?

    Finding.new(key: :over_capacity, severity: :error,
                message: "#{over.size} #{'car'.pluralize(over.size)} over capacity",
                ride_ids: over.map(&:id))
  end

  # --- checks the board does not make --------------------------------------

  # Catches a real bug: marking a driver "not driving" nils their own
  # driver_ride_id but leaves their passengers pointing at them, so the riders
  # sit in a car that is not coming.
  def drivers_out_with_passengers
    orphaned = @board.driver_rides.select { |d| d.out? && d.passengers.any?(&:active?) }
    return if orphaned.empty?

    riders = orphaned.flat_map { |d| d.passengers.select(&:active?) }
    Finding.new(key: :driver_out_with_passengers, severity: :error,
                message: "#{riders.size} #{'rider'.pluralize(riders.size)} are in a car whose driver is marked out",
                ride_ids: riders.map(&:id))
  end

  # A driver cannot collect someone whose address nobody knows.
  def riders_without_a_pickup
    seated = @board.cars.flat_map(&:passengers)
    blank = seated.reject { |r| r.address.present? }
    return if blank.empty?

    Finding.new(key: :rider_no_pickup, severity: :error,
                message: "#{blank.size} seated #{'rider'.pluralize(blank.size)} have no pickup address",
                ride_ids: blank.map(&:id))
  end

  def no_drivers
    return if @board.cars.any?

    Finding.new(key: :no_drivers, severity: :error,
                message: 'Nobody is driving', ride_ids: [])
  end

  # Same person needing a ride to two things at nearly the same moment.
  #
  # The window is deliberately tight. Excluding same-day events entirely would
  # make a same-day conflict undetectable, which is the only kind there is; but
  # a wide window flags Sunday School against Sunday Service every week, and a
  # warning that always fires is one nobody reads. An hour apart is two
  # services you can attend both of. Half an hour apart is a problem.

  # Delegates to the board's same-day map, so the badge on a person and this
  # summary line can never disagree — and so DRIVERS elsewhere count too, which
  # the old query (Ride.active.riders, ±45 minutes) missed entirely. The
  # services sit 60 minutes apart, so the overlap window meant the check never
  # fired on the one mistake people actually make: signing up for both times.
  def double_booked
    map = @board.elsewhere
    return if map.empty?

    lines = @board.rides.select(&:active?).filter_map do |ride|
      labels = ride.user_id && map[ride.user_id]
      "#{ride.display_name} is #{labels.join(', and ')}" if labels
    end.uniq

    Finding.new(key: :double_booked, severity: :warn,
                message: lines.to_sentence,
                ride_ids: @board.rides.select { |r| r.user_id && map.key?(r.user_id) }.map(&:id))
  end

end
