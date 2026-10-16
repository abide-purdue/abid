require_relative 'components'
require_relative 'board_helpers'

# The right-hand rail: per-person details, or the full roster for the occurrence.
class Components::BoardRail < Phlex::HTML
  include BoardHelpers

  def initialize(board:, leader: false, tab: :details)
    @board = board
    @leader = leader
    @tab = tab
    @focus = board.focused
  end

  def view_template
    div(class: 'flex-none w-[308px] border-l border-line flex flex-col min-h-0') do
      tabs
      @tab == :roster ? roster_pane : details_pane
    end
  end

  private

  def tabs
    div(class: 'flex-none flex gap-1 px-3.5 pt-3') do
      tab_link('Details', :details)
      tab_link('Roster', :roster)
    end
  end

  def tab_link(label, id)
    active = @tab == id
    a(
      href: board_url(tab: (id == :roster ? 'roster' : nil)),
      class: [
        'flex-1 text-center cursor-pointer font-semibold text-[11.5px] px-2.5 py-2 rounded-[7px] no-underline',
        active ? 'bg-ink text-ink-invert' : 'bg-ink/5 text-ink/55 hover:text-ink'
      ].join(' ')
    ) { label }
  end

  # --- details -------------------------------------------------------------

  def details_pane
    div(class: 'flex-1 overflow-y-auto p-3.5 flex flex-col gap-3.5') do
      @focus ? person_form : no_focus
    end
  end

  def no_focus
    div(class: 'px-1.5 py-[30px] text-[13px] leading-[1.6] text-ink/65') do
      'Pick anyone on the board — or a name in the waiting list — to fill in their phone, pickup spot, seats and notes.'
    end
  end

  def person_form
    ride = @focus

    div(class: 'flex flex-col gap-3.5') do
      div(class: 'flex items-center gap-2') do
        span(class: role_badge_class(ride)) { ride.role.upcase }
        span(class: 'font-display font-bold text-[17px] capitalize') { ride.display_name }
      end

      action_form("rides/#{ride.id}", method: 'patch', class: 'flex flex-col gap-3.5') do
        if ride.guest?
          guest_fields(ride)
        else
          labeled('Full name') { text_field('name', ride.user&.name) }
          labeled('Phone') { text_field('phone', ride.user&.phone, mono: true, placeholder: '(000) 000-0000') }
          labeled(ride.driver? ? 'Starts from' : 'Pickup spot') do
            text_field('pickup_address', ride.address, placeholder: 'Street address or landmark')
          end

          div(class: 'flex gap-2.5') do
            div(class: 'flex-1') { labeled('Riding or driving') { role_select(ride) } }
            div(class: 'w-24') { labeled('Seats') { seats_field(ride) } } if ride.driver?
          end
        end

        div(class: 'flex gap-2.5') do
          div(class: 'flex-1') { labeled('Zone') { zone_select(ride) } }
        end

        if ride.driver?
          # The church van: it parks, people walk to it, it leaves. Optimize
          # fills it first (a walked seat costs zero driving) and never asks
          # it to tour campus.
          label(class: 'flex items-center gap-2 text-[12.5px]') do
            input(type: 'hidden', name: 'meet_at_pickup', value: '0')
            input(type: 'checkbox', name: 'meet_at_pickup', value: '1',
                  checked: ride.meet_at_pickup, disabled: !@leader, class: 'accent-accent')
            plain 'Riders meet at the car — fills first, drives straight to the venue'
          end
        end

        labeled('Notes') { notes_field(ride) }

        if @leader
          button(type: 'submit', class: 'board-btn-solid w-full') { 'Save details' }
        end
      end

      person_actions(ride) if @leader
    end
  end

  def role_badge_class(ride)
    base = 'font-mono text-[9px] font-semibold tracking-[.09em] px-[7px] py-[3px] rounded-[5px] '
    base + (ride.driver? ? 'bg-accent-tint-strong text-accent' : 'bg-ink/[.07] text-ink/70')
  end

  def labeled(label, &block)
    div(class: 'flex flex-col gap-[5px]') do
      span(class: 'board-label') { label }
      yield
    end
  end

  def text_field(name, value, mono: false, placeholder: nil)
    input(
      type: 'text',
      name: name,
      value: value.to_s,
      placeholder: placeholder,
      disabled: !@leader,
      class: "board-input #{mono ? 'font-mono' : ''}"
    )
  end

  def seats_field(ride)
    input(
      type: 'number',
      name: 'seats',
      min: 1,
      max: 20,
      value: ride.capacity,
      disabled: !@leader,
      class: 'board-input font-mono font-medium'
    )
  end

  # Everyone who reacts to a sign-up arrives as a rider — the emoji does not say
  # which they meant. Without this, turning one into a driver meant deleting the
  # ride and adding them back, for every driver, every week.
  def role_select(ride)
    select(name: 'role', disabled: !@leader, class: 'board-input') do
      option(value: 'rider', selected: ride.rider?) { 'Riding' }
      option(value: 'driver', selected: ride.driver?) { 'Driving' }
    end
  end

  def zone_select(ride)
    select(name: 'zone', disabled: !@leader, class: 'board-input') do
      option(value: '', selected: ride.zone.blank?) { '—' }
      Location::ZONES.each do |zone|
        option(value: zone, selected: ride.zone == zone) { zone }
      end
    end
  end

  def notes_field(ride)
    textarea(
      name: 'note',
      rows: 3,
      disabled: !@leader,
      placeholder: 'Car seat needed, gets picked up at the back door…',
      class: 'board-input resize-y text-[12.5px] leading-[1.5]'
    ) { ride.note.to_s }
  end

  def person_actions(ride)
    div(class: 'flex gap-2 pt-1.5') do
      action_form('toggle-out', ride_id: ride.id, class: 'flex-1') do
        button(
          type: 'submit',
          class: "board-btn w-full #{ride.out? ? 'bg-accent-tint' : ''}"
        ) { toggle_label(ride) }
      end

      action_form("rides/#{ride.id}", method: 'delete', class: 'contents') do
        button(
          type: 'submit',
          title: 'remove from roster',
          data_confirm: "Remove #{ride.display_name} from this event?",
          class: 'border border-danger/25 bg-surface text-danger font-semibold text-xs px-3 py-[9px] rounded-[7px] cursor-pointer hover:bg-danger-tint'
        ) { 'Remove' }
      end
    end
  end

  def toggle_label(ride)
    if ride.driver?
      ride.out? ? 'Mark as driving today' : 'Not driving today'
    else
      ride.out? ? 'Back in the queue' : 'Mark not coming'
    end
  end

  # --- roster --------------------------------------------------------------

  def roster_pane
    div(class: 'flex-1 overflow-y-auto p-3.5 flex flex-col gap-[18px]') do
      roster_section('Drivers', @board.driver_rides) { |r| driver_meta(r) }
      add_drivers_button if @leader
      roster_section('Riders', @board.rider_rides) { |r| r.zone_short }
      add_person if @leader
      add_guest if @leader
    end
  end

  def roster_section(label, rides, &meta)
    div(class: 'flex flex-col gap-[7px]') do
      div(class: 'flex items-baseline gap-[7px]') do
        span(class: 'board-label') { label }
        span(class: 'font-mono text-[10px] text-ink/60') { rides.size.to_s }
      end
      rides.each { |ride| roster_row(ride, meta.call(ride)) }
      if rides.empty?
        span(class: 'text-[12px] text-ink/55 px-0.5') { "No #{label.downcase} yet." }
      end
    end
  end

  def driver_meta(ride)
    return 'not driving' if ride.out?
    "#{ride.capacity} seats · #{ride.zone_short}"
  end

  def roster_row(ride, meta)
    focused = @board.focus_ride_id == ride.id
    a(
      href: board_url(focus: ride.id),
      class: [
        'flex items-center gap-2 px-2.5 py-2 rounded-[7px] border no-underline text-ink',
        focused ? 'border-ink bg-ink/[.06]' : 'border-line bg-surface hover:border-accent'
      ].join(' ')
    ) do
      span(class: "flex-1 text-[12.5px] capitalize #{ride.driver? ? 'font-semibold' : 'font-medium'}") { ride.display_name }
      span(class: 'board-meta') { meta.to_s }
    end
  end

  # A plus-one has no account: name, who they came with, and a pickup only if
  # it differs from the host's. The box holds just their own override, so
  # saving the form never copies the host's address onto them and severs the
  # "same pickup" link.
  def guest_fields(ride)
    labeled('Name') { text_field('name', ride.guest_name) }
    host = ride.host_ride
    span(class: 'text-[12px] text-ink/65') do
      if host
        "Plus-one of #{host.display_name} — not in the Discord. Rides in their car; " \
          'moves when they move.'
      else
        'Plus-one — whoever brought them is no longer on this board, so they are seated on their own.'
      end
    end
    labeled('Pickup spot') do
      text_field('pickup_address', ride.pickup_address,
                 placeholder: host ? "Same as #{host.display_name}" : 'Street address or landmark')
    end
  end

  # Someone not in the Discord (issue #22), linked to whoever brought them.
  def add_guest
    hosts = @board.rides.select { |r| r.active? && !r.guest? }.sort_by { |r| r.display_name.downcase }
    return if hosts.empty?

    div(class: 'flex flex-col gap-2.5 p-3 bg-surface-sunk border border-line rounded-[9px]') do
      span(class: 'board-label') { 'Add a plus-one' }
      span(class: 'text-[11.5px] text-ink/60') { 'Not in the Discord? They ride in the same car as whoever brought them.' }
      action_form('guests', class: 'flex flex-col gap-2.5') do
        input(type: 'text', name: 'name', required: true, placeholder: 'Their name',
              class: 'board-input w-full text-[12.5px]')
        select(name: 'host_ride_id', required: true, class: 'board-input w-full text-[12.5px]') do
          option(value: '') { 'Coming with…' }
          hosts.each { |h| option(value: h.id) { "#{h.display_name}#{' (driving)' if h.driver?}" } }
        end
        button(type: 'submit', class: 'board-btn w-full') { 'Add plus-one' }
      end
    end
  end

  def add_person
    div(class: 'flex flex-col gap-2.5 p-3 bg-surface-sunk border border-line rounded-[9px]') do
      span(class: 'board-label') { 'Add someone' }
      action_form('rides', class: 'flex flex-col gap-2.5') do
        user_select
        # No zone picker: the person already has one, from the home address on
        # their member page, and `RideDetails.create_for` uses it. Asking again
        # invited a different answer for no reason — and a zone typed here
        # would quietly override the address the optimizer actually routes
        # from. If someone is somewhere unusual this week, the details rail to
        # the left is where you say so, on the ride rather than in passing.
        select(name: 'role', class: 'board-input w-full text-[12.5px]') do
          option(value: 'rider') { 'Rider' }
          option(value: 'driver') { 'Driver' }
        end
        button(type: 'submit', class: 'board-btn-solid w-full') { "Add to #{@board.event.name}" }
      end
    end
  end

  # People come from the Discord member sync, so this picks an existing user
  # rather than the design's free-text name field — a typo here would otherwise
  # create a second person who can never be matched to their Discord account.
  #
  # Active members only. The sync brings in everyone who has ever joined the
  # server, so this was a 271-name dropdown of mostly alumni to find the one
  # person standing in front of you.
  def user_select
    taken = @board.rides.map(&:user_id)
    candidates = User.active.where.not(id: taken).by_name.limit(500)

    if candidates.empty?
      span(class: 'text-[12px] text-ink/60') { 'Everyone active is already on this board.' }
    else
      select(name: 'user_id', required: true, class: 'board-input text-[12.5px]') do
        option(value: '') { 'Choose a person…' }
        candidates.each { |u| option(value: u.id) { u.display_name } }
      end
    end
  end
end
